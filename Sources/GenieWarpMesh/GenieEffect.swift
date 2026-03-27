//
//  GenieEffect.swift
//  GenieWarpMesh
//
//  © 2026 usagimaru.
//  CGSSetWindowWarp プライベート API を使用したジニーエフェクトの実装。
//

import Cocoa
import QuartzCore
import CGSPrivate

// MARK: - GenieEffect

/// ウインドウにジニーエフェクトを適用する。
///
/// `minimize(window:to:direction:completion:)` でウインドウをターゲット矩形に吸い込み、`restore(window:from:direction:completion:)` で復元する。
///
/// ## 座標系
/// 全ての public メソッドの矩形パラメータは **Cocoa座標系 (左下原点)** を使用する。
/// `NSWindow.frame` や `NSScreen.frame` の値をそのまま渡せる。
///
/// ## デバッグオーバーレイ
/// ``debugOverlayReceiver`` に ``GenieDebugOverlay`` 準拠のオブジェクトを設定すると、アニメーション中のカーブ軌跡やメッシュ外枠データを受信できる。
/// ライブラリには組み込みの実装として ``DebugOverlayWindow`` が提供されている。
public class GenieEffect {

	// MARK: - Configuration

	/// アニメーションの長さ（秒）
	public var duration: TimeInterval = 0.5

	/// デバッグオーバーレイ（設定するとカーブ軌跡データを出力する）
	public weak var debugOverlayReceiver: GenieDebugOverlay?

	/// アニメーション中の progress 値を通知するコールバック (0.0〜1.0)
	public var progressHandler: ((Double) -> Void)?

	// MARK: - Tuning Parameters

	/// 収縮の smoothstep 区間: progress 0.0〜widthEnd で完了
	public var widthEnd: CGFloat = 0.4

	/// 移動の smoothstep 開始点
	public var slideStart: CGFloat = 0.15

	/// 移動の smoothstep 終了点
	private let slideEnd: CGFloat = 1.0

	/// 順再生 (minimize) の rawT 開始カットオフ (0.0〜1.0)
	public var minimizeRawTStart: CGFloat = 0.0

	/// 順再生 (minimize) の rawT 終了カットオフ (0.0〜1.0)
	public var minimizeRawTEnd: CGFloat = 1.0

	/// 逆再生 (restore) の rawT 開始カットオフ (0.0〜1.0)
	public var restoreRawTStart: CGFloat = 0.0

	/// 逆再生 (restore) の rawT 終了カットオフ (0.0〜1.0)
	public var restoreRawTEnd: CGFloat = 1.0

	/// 退避移動がある場合に開始カットオフを無効化する
	public var skipCutoffOnRetreat: Bool = true

	/// イージングカーブの種類
	public var easingType: EasingType = .easeInOutQuart

	/// 退避移動のイージングカーブの種類
	public var retreatEasingType: EasingType = .easeInQuad

	/// 退避移動の区間終了点 (progress 0.0〜retreatEnd で退避完了)
	public var retreatEnd: CGFloat = 0.4

	/// 間延びの最大強度 (trailing辺の遅延度合い)
	public var stretchPower: CGFloat = 2.0

	/// カーブ制御点 P1 の位置 (0〜1, P0→P3 間)
	public var curveP1Ratio: CGFloat = 0.45

	/// カーブ制御点 P2 の位置 (0〜1, P0→P3 間)
	public var curveP2Ratio: CGFloat = 0.65

	// MARK: - Mesh Warp Configuration

	/// メッシュグリッドの列数
	public var gridWidth = 8

	/// メッシュグリッドの行数（曲線の解像度を上げるため多めに）
	public var gridHeight = 20

	/// アダプティブメッシュ: 方向に応じて解像度を動的に調整する
	public var adaptiveMesh = true

	/// アダプティブメッシュの最小分割数
	private let adaptiveMin = 5

	/// アダプティブメッシュの最大分割数
	private let adaptiveMax = 20

	/// 近接エッジ間の最小距離 (pt)。これを下回ると補正フレームが生成される。
	private let minEdgeGap: CGFloat = 20.0

	/// アニメーション中に使用される実効グリッドサイズ
	private var effectiveGridWidth = 8
	private var effectiveGridHeight = 20

	// MARK: - State

	private weak var window: NSWindow?
	private var displayLink: CADisplayLink?
	private var startTime: CFTimeInterval = 0
	private var originalFrame: CGRect = .zero
	private var targetRect: CGRect = .zero
	private var direction: GenieDirection = .bottom
	private var isAnimating = false
	private var isReversed = false
	private var completion: (() -> Void)?

	/// アニメーション用の補正フレーム (Cocoa座標系)。nil なら補正なし。
	private var animationCorrectedFrame: CGRect?

	// MARK: - Initialization

	public init() {}

	deinit {
		stopDisplayLink()
	}

	// MARK: - Public API

	/// ウインドウをターゲット矩形に向かってワープ・最小化する。
	///
	/// ベジェカーブのパスに沿ってウインドウを変形し、`targetRect` に吸い込む。完了後、ウインドウは非表示になるが閉じられない。
	///
	/// - Parameters:
	///   - window: 最小化するウインドウ。
	///   - targetRect: ワープ先のスクリーン座標矩形 (Cocoa座標系: 左下原点。例: Dock アイコンのフレーム)。
	///   - direction: ワープエフェクトの方向。デフォルトは `.auto` で、ウインドウとターゲットの相対位置から自動判定する。
	///   - completion: アニメーション完了時に呼ばれるコールバック。
	public func minimize(window: NSWindow,
						 to targetRect: CGRect,
						 direction: GenieDirection = .auto,
						 completion: (() -> Void)? = nil) {
		guard !isAnimating else { return }

		// 前回の minimize でワープが残っている場合にリセット
		resetMeshWarp(for: window)

		let resolvedDirection = direction.resolved(from: window.frame, to: targetRect)

		self.window = window
		self.targetRect = targetRect
		self.direction = resolvedDirection
		self.originalFrame = window.frame
		self.isReversed = false
		self.completion = completion

		startAnimation()
	}

	/// 最小化されたウインドウを逆再生ワープで復元する。
	///
	/// ウインドウは `targetRect` から元のフレームに向かって展開される。
	/// アニメーション開始前に完全にワープされたメッシュが適用され、ターゲット矩形から出現するように見える。
	///
	/// - Parameters:
	///   - window: 復元するウインドウ。
	///   - targetRect: 復元元のスクリーン座標矩形 (Cocoa座標系: 左下原点)。
	///   - direction: ワープエフェクトの方向。デフォルトは `.auto` で、ウインドウとターゲットの相対位置から自動判定する。
	///   - completion: アニメーション完了時に呼ばれるコールバック。
	public func restore(window: NSWindow,
						from targetRect: CGRect,
						direction: GenieDirection = .auto,
						completion: (() -> Void)? = nil) {
		guard !isAnimating else { return }

		// 前回の minimize でワープが残っている場合にリセット
		resetMeshWarp(for: window)

		let resolvedDirection = direction.resolved(from: window.frame, to: targetRect)

		self.window = window
		self.targetRect = targetRect
		self.direction = resolvedDirection
		self.originalFrame = window.frame
		self.isReversed = true
		self.completion = completion

		// 補正フレームを先に計算（applyMeshWarp で退避位置を使えるようにする）
		animationCorrectedFrame = computeCorrectedFrame(
			sourceFrame: window.frame,
			targetFrame: targetRect,
			direction: resolvedDirection
		)

		// 吸い込み済み状態のワープを適用してから表示
		window.alphaValue = 0
		window.order(.above, relativeTo: 0)
		applyMeshWarp(to: window, progress: 1.0, retreatProgress: animationCorrectedFrame != nil ? 1.0 : 0.0)
		window.alphaValue = 1

		startAnimation()
	}

	// MARK: - Corrected Frame

	/// ソースとターゲットが近すぎる場合に補正ウインドウフレームを計算する。
	///
	/// `sourceFrame` と `targetFrame` の近接辺間の距離が `minEdgeGap` 未満の場合、
	/// ベジェカーブが正しく描画されるよう、ソースフレームをターゲットから離す方向にずらす。
	/// 補正が不要な場合は `nil` を返す。
	///
	/// 座標系: Cocoa (左下原点)。
	public func computeCorrectedFrame(sourceFrame: CGRect,
									  targetFrame: CGRect,
									  direction: GenieDirection) -> CGRect?
	{
		let direction = direction.resolved(from: sourceFrame, to: targetFrame)
		let gap: CGFloat
		switch direction {
		case .auto, .bottom:
			// ウインドウ下端 ↔ ターゲット上端
			gap = sourceFrame.origin.y - targetFrame.maxY
		case .top:
			// ウインドウ上端 ↔ ターゲット下端
			gap = targetFrame.origin.y - sourceFrame.maxY
		case .left:
			// ウインドウ左端 ↔ ターゲット右端
			gap = sourceFrame.origin.x - targetFrame.maxX
		case .right:
			// ウインドウ右端 ↔ ターゲット左端
			gap = targetFrame.origin.x - sourceFrame.maxX
		}

		guard gap < minEdgeGap else { return nil }

		let shortage = minEdgeGap - gap
		var corrected = sourceFrame
		switch direction {
		case .auto, .bottom:
			corrected.origin.y += shortage  // 上に退避
		case .top:
			corrected.origin.y -= shortage  // 下に退避
		case .left:
			corrected.origin.x += shortage  // 右に退避
		case .right:
			corrected.origin.x -= shortage  // 左に退避
		}
		return corrected
	}

	// MARK: - Debug Overlay (External Layout Update)

	/// 指定されたフレームのカーブおよびレイアウトデータでデバッグオーバーレイを更新する。
	///
	/// ソースまたはターゲットウインドウが移動した際にオーバーレイ表示を更新するためにアプリ側から呼び出す。
	/// アニメーションは実行せず、カーブデータの計算と `debugOverlayReceiver` への送信のみ行う。
	///
	/// 座標系: Cocoa (左下原点)。
	public func updateDebugOverlayForCurrentLayout(sourceFrame: CGRect,
												   targetFrame: CGRect,
												   direction: GenieDirection)
	{
		guard let overlay = debugOverlayReceiver else { return }
		guard let screenHeight = NSScreen.main?.frame.height else { return }
		
		let resolvedDirection = direction.resolved(from: sourceFrame, to: targetFrame)

		// 一時的に状態を設定してカーブを計算
		let savedTarget = self.targetRect
		let savedDirection = self.direction
		self.targetRect = targetFrame
		self.direction = resolvedDirection

		let cgFrameY = screenHeight - sourceFrame.origin.y - sourceFrame.height
		let paths = computeCurvePaths(frame: sourceFrame, cgFrameY: cgFrameY, screenHeight: screenHeight)
		let ext = computeExtensionEndpoints(paths: paths, targetFrame: targetFrame, direction: resolvedDirection, screenHeight: screenHeight)

		// 補正カーブ（近接時のみ）
		var correctedCurveData: CorrectedCurveData?
		if let correctedFrame = computeCorrectedFrame(sourceFrame: sourceFrame, targetFrame: targetFrame, direction: resolvedDirection) {
			correctedCurveData = computeCorrectedCurveDataInternal(
				correctedFrame: correctedFrame, targetFrame: targetFrame,
				direction: resolvedDirection, screenHeight: screenHeight
			)
		}

		// 状態を復元
		self.targetRect = savedTarget
		self.direction = savedDirection

		overlay.receiveCurveGuideData(
			leftCurve: (p0: paths.leftP0, p1: paths.leftP1, p2: paths.leftP2, p3: paths.leftP3),
			rightCurve: (p0: paths.rightP0, p1: paths.rightP1, p2: paths.rightP2, p3: paths.rightP3),
			sourceFrame: sourceFrame,
			targetFrame: targetFrame,
			fitRect: paths.fitRect,
			leftExtensionEnd: ext.left,
			rightExtensionEnd: ext.right,
			correctedData: correctedCurveData
		)
	}

	// MARK: - Animation Lifecycle

	private func startAnimation() {
		isAnimating = true

		// 補正フレームの計算（近接時のみ）
		animationCorrectedFrame = computeCorrectedFrame(
			sourceFrame: originalFrame,
			targetFrame: targetRect,
			direction: direction
		)

		// 再生方向に応じたカットオフ値で startTime をオフセット
		// 退避移動がある場合はオプションに応じて開始カットオフを無効化（順再生のみ）
		var cutoffStart = isReversed ? restoreRawTStart : minimizeRawTStart
		if skipCutoffOnRetreat && animationCorrectedFrame != nil && !isReversed {
			cutoffStart = 0.0
		}
		startTime = CACurrentMediaTime() - (cutoffStart * duration)

		// アダプティブメッシュ: 方向に応じて解像度を動的に調整
		if adaptiveMesh {
			switch direction {
			case .auto, .bottom, .top:
				// 縦方向の吸い込み → 縦解像度を上げ、横解像度を下げる
				effectiveGridWidth = adaptiveMin
				effectiveGridHeight = adaptiveMax
			case .left, .right:
				// 横方向の吸い込み → 横解像度を上げ、縦解像度を下げる
				effectiveGridWidth = adaptiveMax
				effectiveGridHeight = adaptiveMin
			}
		} else {
			effectiveGridWidth = gridWidth
			effectiveGridHeight = gridHeight
		}

		// デバッグオーバーレイにカーブ情報を送る
		updateDebugOverlay()

		startDisplayLink()
	}

	private func finishAnimation() {
		stopDisplayLink()
		isAnimating = false
		animationCorrectedFrame = nil

		if let window = window {
			if !isReversed {
				// ワープを解除せず orderOut のみ行う。
				// resetMeshWarp → orderOut の順だと、ワープ解除で元矩形が一瞬描画されてちらつく。
				// orderOut → resetMeshWarp でもシステム標準フェードアウトが介在して同様。
				// ワープ適用状態のまま非表示にし、次回表示前にリセットする。
				let animationBehavior = window.animationBehavior
				window.animationBehavior = .none
				window.orderOut(nil)
				window.animationBehavior = animationBehavior
			} else {
				resetMeshWarp(for: window)
			}
		}

		// アニメーション終了時にメッシュ外枠表示をクリア
		debugOverlayReceiver?.clearMeshEdgePoints()

		DispatchQueue.main.async { [weak self] in
			self?.completion?()
		}
	}

	// MARK: - Display Link

	private func startDisplayLink() {
		guard let screen = window?.screen ?? NSScreen.main else { return }
		let link = screen.displayLink(target: self, selector: #selector(displayLinkCallback(_:)))
		link.add(to: .main, forMode: .common)
		displayLink = link
	}

	private func stopDisplayLink() {
		displayLink?.invalidate()
		displayLink = nil
	}

	@objc private func displayLinkCallback(_ link: CADisplayLink) {
		tick()
	}

	// MARK: - Per-frame Update

	private func tick() {
		guard isAnimating, let window = window else {
			if isAnimating { finishAnimation() }
			return
		}

		let elapsed = CACurrentMediaTime() - startTime
		let rawT = min(elapsed / duration, 1.0)

		// イージングカーブをそのまま適用。
		// 逆再生の場合は関数を反転。
		let t = genieEase(rawT, reversed: isReversed)


		// 退避移動の進行度
		// rawT（生の時間値）を retreatEnd 区間で 0→1 にマッピングし、retreatEasing を適用。
		// rawT ベースを使う理由:
		//   イージング済みの progress t を使うと、退避にもメインイージングが二重適用されてぎこちなくなる。生の時間値 + 退避独自のイージングで滑らかな退避を実現する。
		let retreatProgress: CGFloat
		if animationCorrectedFrame != nil {
			let rawDirectional = isReversed ? (1.0 - rawT) : rawT
			let linearT = min(max(CGFloat(rawDirectional) / retreatEnd, 0.0), 1.0)
			retreatProgress = CGFloat(retreatEasingType.function(Double(linearT)))
		} else {
			retreatProgress = 0.0
		}

		// 退避移動がある場合はオプションに応じて終了カットオフを無効化（逆再生のみ）
		var cutoffEnd = isReversed ? restoreRawTEnd : minimizeRawTEnd
		if skipCutoffOnRetreat && animationCorrectedFrame != nil && isReversed {
			cutoffEnd = 1.0
		}
		if rawT >= cutoffEnd {
			// 最終フレーム: cutoffEnd 時点の値でワープ適用してから終了
			let finalT = genieEase(Double(cutoffEnd), reversed: isReversed)
			let finalRetreat: CGFloat
			if animationCorrectedFrame != nil {
				let rawDir = isReversed ? (1.0 - cutoffEnd) : cutoffEnd
				let lT = min(max(rawDir / retreatEnd, 0.0), 1.0)
				finalRetreat = CGFloat(retreatEasingType.function(Double(lT)))
			} else {
				finalRetreat = 0.0
			}
			applyMeshWarp(to: window, progress: finalT, retreatProgress: finalRetreat)
			progressHandler?(finalT)
			finishAnimation()
		} else {
			applyMeshWarp(to: window, progress: t, retreatProgress: retreatProgress)
			progressHandler?(t)
		}
	}

	/// easingType に基づいてイージングを計算
	private func genieEase(_ t: Double, reversed: Bool = false) -> Double {
		var r = easingType.function(t)
		if reversed { r = 1.0 - r }
		return r
	}

	// MARK: - Debug Overlay

	private func updateDebugOverlay() {
		guard let overlay = debugOverlayReceiver else { return }
		guard let screenHeight = NSScreen.main?.frame.height else { return }

		let frame = originalFrame
		let cgFrameY = screenHeight - frame.origin.y - frame.height
		let paths = computeCurvePaths(frame: frame, cgFrameY: cgFrameY, screenHeight: screenHeight)
		let ext = computeExtensionEndpoints(paths: paths, targetFrame: targetRect, direction: direction, screenHeight: screenHeight)

		// 補正カーブ（近接時のみ）
		var correctedCurveData: CorrectedCurveData?
		if let correctedFrame = computeCorrectedFrame(sourceFrame: frame, targetFrame: targetRect, direction: direction) {
			correctedCurveData = computeCorrectedCurveDataInternal(
				correctedFrame: correctedFrame, targetFrame: targetRect,
				direction: direction, screenHeight: screenHeight
			)
		}

		overlay.receiveCurveGuideData(
			leftCurve: (p0: paths.leftP0, p1: paths.leftP1, p2: paths.leftP2, p3: paths.leftP3),
			rightCurve: (p0: paths.rightP0, p1: paths.rightP1, p2: paths.rightP2, p3: paths.rightP3),
			sourceFrame: frame,
			targetFrame: targetRect,
			fitRect: paths.fitRect,
			leftExtensionEnd: ext.left,
			rightExtensionEnd: ext.right,
			correctedData: correctedCurveData
		)
	}

	/// 補正フレームからカーブデータを計算する
	///
	/// correctedFrame に基づいてフルカーブ（P0〜P3）をそのまま生成する。
	/// メッシュは computeGeniePoint 内で同じ correctedFrame から同一カーブを計算するため、ガイド線とメッシュの移動パスが完全に一致する。
	///
	/// trailing 辺がカーブ P0 に到達するのは progress 初期のみで、
	/// retreat 完了時には t=rowSlide まで進んでいるが、これはカーブ形状の自然な挙動であり、ガイドカーブとの整合性に影響しない。
	private func computeCorrectedCurveDataInternal(
		correctedFrame: CGRect,
		targetFrame: CGRect,
		direction: GenieDirection,
		screenHeight: CGFloat
	) -> CorrectedCurveData {
		let cgFrameY = screenHeight - correctedFrame.origin.y - correctedFrame.height
		let paths = computeCurvePaths(frame: correctedFrame, cgFrameY: cgFrameY, screenHeight: screenHeight)
		let ext = computeExtensionEndpoints(paths: paths, targetFrame: targetFrame, direction: direction, screenHeight: screenHeight)

		return CorrectedCurveData(
			leftCurve: (p0: paths.leftP0, p1: paths.leftP1, p2: paths.leftP2, p3: paths.leftP3),
			rightCurve: (p0: paths.rightP0, p1: paths.rightP1, p2: paths.rightP2, p3: paths.rightP3),
			leftExtensionEnd: ext.left,
			rightExtensionEnd: ext.right,
			sourceFrame: correctedFrame
		)
	}

	/// P3 (near edge) から far edge への延長線終点を計算する (CG座標系)
	private func computeExtensionEndpoints(
		paths: CurvePaths,
		targetFrame: CGRect,
		direction: GenieDirection,
		screenHeight: CGFloat
	) -> (left: CGPoint, right: CGPoint) {
		let targetCGY = screenHeight - targetFrame.origin.y - targetFrame.height
		let targetTop = targetCGY
		let targetBottom = targetCGY + targetFrame.height

		switch direction {
		case .auto, .bottom:
			// P3 は targetTop (near edge), far edge は targetBottom
			return (
				left: CGPoint(x: paths.leftP3.x, y: targetBottom),
				right: CGPoint(x: paths.rightP3.x, y: targetBottom)
			)
		case .top:
			// P3 は targetBottom (near edge), far edge は targetTop
			return (
				left: CGPoint(x: paths.leftP3.x, y: targetTop),
				right: CGPoint(x: paths.rightP3.x, y: targetTop)
			)
		case .left:
			// P3 は maxX (near edge), far edge は origin.x
			return (
				left: CGPoint(x: targetFrame.origin.x, y: paths.leftP3.y),
				right: CGPoint(x: targetFrame.origin.x, y: paths.rightP3.y)
			)
		case .right:
			// P3 は origin.x (near edge), far edge は maxX
			return (
				left: CGPoint(x: targetFrame.maxX, y: paths.leftP3.y),
				right: CGPoint(x: targetFrame.maxX, y: paths.rightP3.y)
			)
		}
	}

	// MARK: - Mesh Warp

	private func resetMeshWarp(for window: NSWindow) {
		let cid = CGSMainConnectionID()
		let wid = CGSWindowID(window.windowNumber)
		CGSSetWindowWarp(cid, wid, 0, 0, nil)
	}

	/// progress: 0.0 = 通常の矩形, 1.0 = 完全に吸い込まれた状態
	/// retreatProgress: 退避移動の進行度 (0→1)。生の時間 t から smoothstep で計算済み。
	private func applyMeshWarp(to window: NSWindow, progress: Double, retreatProgress: CGFloat = 0.0) {
		let cid = CGSMainConnectionID()
		let wid = CGSWindowID(window.windowNumber)
		let frame = originalFrame

		guard let screenHeight = NSScreen.main?.frame.height else { return }

		// Cocoa座標系（左下原点）→ CG座標系（左上原点）
		let cgFrameY = screenHeight - frame.origin.y - frame.height

		let p = CGFloat(progress)

		// 退避移動の実装方式（フレーム動的補間）:
		//   retreatProgress に応じて computeGeniePoint に渡すフレームを
		//   originalFrame → correctedFrame へ lerp させる。
		//   各メッシュ点はその時点のフレーム位置に対応したカーブパス上を動くため、
		//   デバッグオーバーレイの補正ガイド線と最終的に一致する。
		//
		//   retreatProgress=0 → computeFrame = originalFrame（元のカーブ）
		//   retreatProgress=1 → computeFrame = correctedFrame（補正カーブ = ガイド線上）
		let computeFrame: CGRect
		let computeCgFrameY: CGFloat
		if let corrected = animationCorrectedFrame {
			// retreatProgress に応じて originalFrame → correctedFrame を補間
			computeFrame = CGRect(
				x: lerp(frame.origin.x, corrected.origin.x, retreatProgress),
				y: lerp(frame.origin.y, corrected.origin.y, retreatProgress),
				width: frame.width,
				height: frame.height
			)
			computeCgFrameY = screenHeight - computeFrame.origin.y - computeFrame.height
		} else {
			computeFrame = frame
			computeCgFrameY = cgFrameY
		}

		let gw = effectiveGridWidth
		let gh = effectiveGridHeight

		var mesh = [CGSWarpPoint](repeating: CGSWarpPoint(
			local: CGSMeshPoint(x: 0, y: 0),
			global: CGSMeshPoint(x: 0, y: 0)
		), count: gw * gh)

		for row in 0..<gh {
			for col in 0..<gw {
				let normalizedX = CGFloat(col) / CGFloat(gw - 1)
				let normalizedY = CGFloat(row) / CGFloat(gh - 1)

				let localX = normalizedX * frame.width
				let localY = normalizedY * frame.height

				let globalPoint = computeGeniePoint(
					normalizedX: normalizedX,
					normalizedY: normalizedY,
					frame: computeFrame,
					cgFrameY: computeCgFrameY,
					screenHeight: screenHeight,
					progress: p
				)

				let index = row * gw + col
				mesh[index] = CGSWarpPoint(
					local: CGSMeshPoint(x: Float(round(localX)), y: Float(round(localY))),
					global: CGSMeshPoint(x: Float(round(globalPoint.x)), y: Float(round(globalPoint.y)))
				)
			}
		}

		CGSSetWindowWarp(cid, wid, Int32(gw), Int32(gh), mesh)

		// デバッグオーバーレイにメッシュ外枠の交点を送る（CG座標系）
		if debugOverlayReceiver != nil {
			var edgePoints = [CGPoint]()
			// 上辺 (row=0), 下辺 (row=gh-1)
			for col in 0..<gw {
				let nx = CGFloat(col) / CGFloat(gw - 1)
				for row in [0, gh - 1] {
					let ny = CGFloat(row) / CGFloat(gh - 1)
					let pt = computeGeniePoint(normalizedX: nx, normalizedY: ny,
											   frame: computeFrame, cgFrameY: computeCgFrameY,
											   screenHeight: screenHeight, progress: p)
					edgePoints.append(pt)
				}
			}
			// 左辺 (col=0), 右辺 (col=gw-1) — 角は上で追加済みなので除外
			for row in 1..<(gh - 1) {
				let ny = CGFloat(row) / CGFloat(gh - 1)
				for col in [0, gw - 1] {
					let nx = CGFloat(col) / CGFloat(gw - 1)
					let pt = computeGeniePoint(normalizedX: nx, normalizedY: ny,
											   frame: computeFrame, cgFrameY: computeCgFrameY,
											   screenHeight: screenHeight, progress: p)
					edgePoints.append(pt)
				}
			}
			debugOverlayReceiver?.receiveMeshEdgePoints(
				edgePoints,
				gridWidth: gw,
				gridHeight: gh,
				screenHeight: screenHeight
			)
		}
	}

	// MARK: - Mesh Warp Geometry
	//
	// ジニーエフェクトの動き:
	//   1. 開始時にはウインドウフレームと完全一致
	//   2. まず幅の収縮が始まる
	//   3. 収縮の途中から下方（ターゲット方向）への移動を開始
	//   4. ウインドウの両端（左上→ターゲット左端、右上→ターゲット右端）を結ぶ
	//      2本の3次ベジェ曲線の内側に沿って歪む
	//
	// カーブ設計 (.bottom の場合):
	//   左辺カーブ: P0=(winLeft, winTop) → P3=(fitLeft, targetTop)
	//   右辺カーブ: P0=(winRight, winTop) → P3=(fitRight, targetTop)
	//   t=0: ウインドウの trailing 辺（上端）
	//   t=1: ターゲットの near 辺（吸い込み口側 = 上端）
	//
	// progress に応じて:
	//   - widthProgress: 幅の収縮度合い（先行して変化）
	//   - slideProgress: 主軸方向の移動度合い（やや遅れて変化）
	//   この2つの独立した progress で各メッシュ行の位置を決定。

	private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
		return a + (b - a) * t
	}

	/// 3次ベジェ曲線上の点を計算する (2D)
	private func cubicBezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, t: CGFloat) -> CGPoint {
		let u = 1.0 - t
		let uu = u * u
		let uuu = uu * u
		let tt = t * t
		let ttt = tt * t
		return CGPoint(
			x: uuu * p0.x + 3.0 * uu * t * p1.x + 3.0 * u * tt * p2.x + ttt * p3.x,
			y: uuu * p0.y + 3.0 * uu * t * p1.y + 3.0 * u * tt * p2.y + ttt * p3.y
		)
	}

	/// 拡張カーブ: t=0〜1 はベジェカーブ、t=1〜tMax は P3→farEnd への直線延長。
	/// カーブと延長線が連続するため、遷移時のジャンプが発生しない。
	///
	/// - Parameters:
	///   - t: 拡張パラメータ (0〜tMax)
	///   - tMax: 拡張カーブの最大値。t=1.0 で P3、t=tMax で farEnd に到達。
	private func extendedCurvePoint(
		_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
		farEnd: CGPoint, t: CGFloat, tMax: CGFloat
	) -> CGPoint {
		if t <= 1.0 {
			return cubicBezier(p0, p1, p2, p3, t: max(t, 0.0))
		}
		// t > 1.0: P3 → farEnd の線形延長
		// s を 0〜1 に正規化 (t=1.0 → s=0, t=tMax → s=1)
		let extensionLength = tMax - 1.0
		let s = extensionLength > 0 ? min((t - 1.0) / extensionLength, 1.0) : 1.0
		return CGPoint(
			x: p3.x + (farEnd.x - p3.x) * s,
			y: p3.y + (farEnd.y - p3.y) * s
		)
	}

	/// カーブパスのデータ (単純な3次ベジェ × 2本)
	struct CurvePaths {
		let leftP0: CGPoint, leftP1: CGPoint, leftP2: CGPoint, leftP3: CGPoint
		let rightP0: CGPoint, rightP1: CGPoint, rightP2: CGPoint, rightP3: CGPoint
		/// ターゲット内の scale-to-fit 矩形 (CG座標系: 左上原点)
		let fitRect: CGRect
	}

	/// ジニーエフェクトの2本の軌跡カーブを生成する。
	///
	/// カーブ設計 (.bottom の場合):
	///   左カーブ: P0=(winLeft, winTop) → P3=(fitLeft, targetTop)
	///   右カーブ: P0=(winRight, winTop) → P3=(fitRight, targetTop)
	///
	///   P0 = trailing辺（吸い込み先から遠い辺）の端点
	///   P3 = ターゲットの near辺（吸い込み口側）の端点
	///
	///   P1.x = P0.x に固定 → カーブ序盤で X 座標が一定（垂直に出発）
	///   P2.x = P3.x に固定 → カーブ終盤でターゲットに滑らかに到達
	///
	///   メッシュの各行の左右端をカーブ上の点から直接取得することで、ウインドウの変形がカーブに正確に沿う。
	private func computeCurvePaths(frame: CGRect, cgFrameY: CGFloat, screenHeight: CGFloat) -> CurvePaths {

		let winLeft = frame.origin.x
		let winRight = frame.maxX
		let winTop = cgFrameY
		let winBottom = cgFrameY + frame.height

		let targetCGY = screenHeight - targetRect.origin.y - targetRect.height
		let targetTop = targetCGY
		let targetBottom = targetCGY + targetRect.height

		// ウインドウのアスペクト比を考慮して、ターゲットに scale-to-fit した終着点座標を計算する。
		// 非正方形ウインドウの場合、カーブの終着幅がターゲット矩形の全幅ではなく、フィット後の幅に収束する。
		let winAspect = frame.width / max(frame.height, 1.0)
		let targetAspect = targetRect.width / max(targetRect.height, 1.0)
		let fitWidth: CGFloat
		let fitHeight: CGFloat
		if winAspect > targetAspect {
			fitWidth = targetRect.width
			fitHeight = targetRect.width / winAspect
		} else {
			fitHeight = targetRect.height
			fitWidth = targetRect.height * winAspect
		}
		let targetCenterX = targetRect.midX
		let targetCenterY = targetCGY + targetRect.height / 2.0

		// フィット後の終着座標（交差軸）
		let fitLeft = targetCenterX - fitWidth / 2.0
		let fitRight = targetCenterX + fitWidth / 2.0
		let fitTop = targetCenterY - fitHeight / 2.0
		let fitBottom = targetCenterY + fitHeight / 2.0

		// scale-to-fit 矩形 (CG座標系)
		// .left/.right ではメッシュが near edge 側に寄るため、
		// fitRect の X 座標を near edge 基準で配置する。
		let fitRect: CGRect
		switch direction {
		case .left:
			// near edge = targetRect.maxX, far edge = maxX - fitWidth
			fitRect = CGRect(x: targetRect.maxX - fitWidth, y: fitTop,
							 width: fitWidth, height: fitHeight)
		case .right:
			// near edge = targetRect.origin.x, far edge = origin.x + fitWidth
			fitRect = CGRect(x: targetRect.origin.x, y: fitTop,
							 width: fitWidth, height: fitHeight)
		default:
			fitRect = CGRect(x: fitLeft, y: fitTop, width: fitWidth, height: fitHeight)
		}

		// カーブ生成:
		//   left/right カーブは交差軸方向の両端を表す。
		//   .bottom/.top: 交差軸=X → leftカーブ=左端, rightカーブ=右端
		//   .left/.right: 交差軸=Y → leftカーブ=上端, rightカーブ=下端
		//
		//   P0 = trailing辺 (吸い込み先から遠い辺)
		//   P3 = near edge (吸い込み口側のフィット座標)
		//   P1/P2: 主軸方向に lerp で制御点比率を適用、交差軸は P0/P3 を維持

		let lP0: CGPoint, lP3: CGPoint, rP0: CGPoint, rP3: CGPoint

		switch direction {
		case .auto, .bottom, .top:
			// 主軸=Y, 交差軸=X
			let trailingY = (direction == .bottom || direction == .auto) ? winTop : winBottom
			let nearY = (direction == .bottom || direction == .auto) ? targetTop : targetBottom
			lP0 = CGPoint(x: winLeft, y: trailingY)
			lP3 = CGPoint(x: fitLeft, y: nearY)
			rP0 = CGPoint(x: winRight, y: trailingY)
			rP3 = CGPoint(x: fitRight, y: nearY)

		case .left, .right:
			// 主軸=X, 交差軸=Y
			let trailingX = (direction == .left) ? winRight : winLeft
			let nearX = (direction == .left) ? targetRect.maxX : targetRect.origin.x
			lP0 = CGPoint(x: trailingX, y: winTop)
			lP3 = CGPoint(x: nearX, y: fitTop)
			rP0 = CGPoint(x: trailingX, y: winBottom)
			rP3 = CGPoint(x: nearX, y: fitBottom)
		}

		// P1/P2: 主軸方向のみ P0→P3 間を lerp、交差軸は P0/P3 の値を維持
		let lP1: CGPoint, lP2: CGPoint, rP1: CGPoint, rP2: CGPoint
		switch direction {
		case .auto, .bottom, .top:
			lP1 = CGPoint(x: lP0.x, y: lerp(lP0.y, lP3.y, curveP1Ratio))
			lP2 = CGPoint(x: lP3.x, y: lerp(lP0.y, lP3.y, curveP2Ratio))
			rP1 = CGPoint(x: rP0.x, y: lerp(rP0.y, rP3.y, curveP1Ratio))
			rP2 = CGPoint(x: rP3.x, y: lerp(rP0.y, rP3.y, curveP2Ratio))
		case .left, .right:
			lP1 = CGPoint(x: lerp(lP0.x, lP3.x, curveP1Ratio), y: lP0.y)
			lP2 = CGPoint(x: lerp(lP0.x, lP3.x, curveP2Ratio), y: lP3.y)
			rP1 = CGPoint(x: lerp(rP0.x, rP3.x, curveP1Ratio), y: rP0.y)
			rP2 = CGPoint(x: lerp(rP0.x, rP3.x, curveP2Ratio), y: rP3.y)
		}

		return CurvePaths(leftP0: lP0, leftP1: lP1, leftP2: lP2, leftP3: lP3,
						  rightP0: rP0, rightP1: rP1, rightP2: rP2, rightP3: rP3,
						  fitRect: fitRect)
	}

	// MARK: - 2段階イージング（連続ベジェ方式）
	//
	// フェーズ境界での速度不連続を排除するため、1本の3次ベジェカーブで「序盤急→中盤溜め→後半再加速」を表現する。
	// 制御点の Y 値で到達量を、X 値でタイミングを制御。

	/// 1次元の3次ベジェ補間 (t → value)
	/// p0〜p3 は (time, value) の制御点。t を入力として value を返す。
	/// 注: t は p0.x〜p3.x の範囲で、ベジェパラメータ u を二分探索で求める。
	private func bezierEase(t: CGFloat,
							p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> CGFloat {
		// t (横軸) からベジェパラメータ u を二分探索
		var lo: CGFloat = 0.0
		var hi: CGFloat = 1.0
		for _ in 0..<16 {
			let mid = (lo + hi) * 0.5
			let x = bezierComponent(mid, a: p0.x, b: p1.x, c: p2.x, d: p3.x)
			if x < t {
				lo = mid
			} else {
				hi = mid
			}
		}
		let u = (lo + hi) * 0.5
		return bezierComponent(u, a: p0.y, b: p1.y, c: p2.y, d: p3.y)
	}

	/// 3次ベジェの1成分を計算
	private func bezierComponent(_ u: CGFloat, a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat) -> CGFloat {
		let inv = 1.0 - u
		let inv2 = inv * inv
		let u2 = u * u
		return inv2 * inv * a + 3.0 * inv2 * u * b + 3.0 * inv * u2 * c + u2 * u * d
	}

	// MARK: - 連続フェーズ制御
	//
	// 各progress値は progress 0.0〜1.0 を通じて連続的に変化する。
	// 硬いフェーズ境界を持たず、重なり合いながら滑らかに進行:
	//
	//   widthProgress:  先行して 0→1 (収縮)
	//   slideProgress:  やや遅れて 0→1 (移動の基準進行度)
	//
	// slideProgress は各メッシュ行の edgeNorm に応じてべき乗で歪ませる:
	//   leading側 (edgeNorm=1): slideProgress^1.0 (そのまま)
	//   trailing側 (edgeNorm=0): slideProgress^3.0 (大きく遅延)
	//   → 進行方向側が先行し、後方が引っ張られて間延びする
	//
	// 各メッシュ行は拡張カーブ (ベジェ + P3→far edge 直線延長) 上を連続的に移動するため、別途のブレンドフェーズは不要。

	/// smoothstep: 指定区間内で 0→1 に滑らかに遷移する区間外では 0 または 1 にクランプされる
	private func smoothstep(edge0: CGFloat, edge1: CGFloat, x: CGFloat) -> CGFloat {
		let t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
		return t * t * (3.0 - 2.0 * t)
	}

	/// フェーズ1: 収縮進行度 (0→1)
	private func computeWidthProgress(_ progress: CGFloat) -> CGFloat {
		return smoothstep(edge0: 0.0, edge1: widthEnd, x: progress)
	}

	/// フェーズ2: leading辺の移動進行度 (0→1)
	///
	/// slideStart〜slideEnd の区間で 0→1 に遷移する。
	/// 開始点のみ二次イーズインで滑らかにし、残りは線形。
	///
	/// 完全な smoothstep を使わない理由:
	/// 全体のイージングは genieEase が担当しており、smoothstep を重ねると二重イージングで終盤が停滞する。
	/// 開始点だけ滑らかにすることで、収縮→移動の遷移時の微分不連続によるカクつきを解消しつつ、終端は線形のまま維持して二重イージングを回避する。
	private func computeSlideProgress(_ progress: CGFloat) -> CGFloat {
		let t = min(max((progress - slideStart) / (slideEnd - slideStart), 0.0), 1.0)
		// 開始側のみ二次イーズイン: t が blendZone 以下では二次カーブ、それ以降は線形に接続する区分関数。
		// blendZone = 0.3 → 移動区間の序盤30%でソフトに立ち上がる。
		//
		// 区分関数 g(t):
		//   t < b:  g = t² / (2b)
		//   t >= b: g = t - b/2
		// g(0)=0, g(b)=b/2, g(1)=1-b/2
		// g'(b-)=b/b=1, g'(b+)=1  → C1連続
		//
		// 出力を 0〜1 に正規化: f(t) = g(t) / g(1) = g(t) / (1 - b/2)
		let b: CGFloat = 0.3
		let scale = 1.0 / (1.0 - b / 2.0)  // ≈ 1.176
		if t < b {
			return (t * t) / (2.0 * b) * scale
		} else {
			return (t - b / 2.0) * scale
		}
	}

	private func computeGeniePoint(normalizedX: CGFloat,
								   normalizedY: CGFloat,
								   frame: CGRect,
								   cgFrameY: CGFloat,
								   screenHeight: CGFloat,
								   progress: CGFloat) -> CGPoint {
		let paths = computeCurvePaths(frame: frame, cgFrameY: cgFrameY, screenHeight: screenHeight)

		let slideProgress = computeSlideProgress(progress)
		let widthProgress = computeWidthProgress(progress)

		// 元のウインドウ上の座標 (CG座標系)
		let winLeft = frame.origin.x
		let winRight = frame.maxX
		let winTopCG = cgFrameY
		let winBottomCG = cgFrameY + frame.height
		let origX = lerp(winLeft, winRight, normalizedX)
		let origY = lerp(winTopCG, winBottomCG, normalizedY)

		// --- 方向に応じたパラメータを抽出 ---
		// 主軸 (main axis): 吸い込み方向の軸。.bottom/.top → Y, .left/.right → X
		// 交差軸 (cross axis): 主軸に直交する軸
		//
		// mainNorm:  主軸方向の正規化座標 (0=trailing辺, 1=leading辺)
		// crossNorm: 交差軸方向の正規化座標 (0〜1, カーブ間補間用)
		// mainAxisDist:  P0→P3 間の主軸方向距離
		// winMainSize:   ウインドウの主軸方向サイズ
		// farEndAxisDist: P3→farEnd 間の主軸方向距離

		let mainNorm: CGFloat   // edgeNorm: 0=trailing, 1=leading
		let crossNorm: CGFloat  // カーブ間補間に使う正規化座標
		let leftFarEnd: CGPoint
		let rightFarEnd: CGPoint
		let mainAxisDist: CGFloat
		let winMainSize: CGFloat

		let isVertical = (direction == .bottom || direction == .top || direction == .auto)

		if isVertical {
			let targetCGY = screenHeight - targetRect.origin.y - targetRect.height
			let targetTop = targetCGY
			let targetBottom = targetCGY + targetRect.height

			// far edge: P3 の交差軸座標を維持し、主軸方向にターゲットの反対辺
			let farY = (direction == .bottom || direction == .auto) ? targetBottom : targetTop
			leftFarEnd = CGPoint(x: paths.leftP3.x, y: farY)
			rightFarEnd = CGPoint(x: paths.rightP3.x, y: farY)

			mainAxisDist = abs(paths.leftP3.y - paths.leftP0.y)
			winMainSize = frame.height
			mainNorm = (direction == .bottom || direction == .auto) ? normalizedY : (1.0 - normalizedY)
			crossNorm = normalizedX
		} else {
			// far edge: P3 から fitWidth 分だけ奥に配置
			let fitW = paths.fitRect.width
			let sign: CGFloat = (direction == .right) ? 1.0 : -1.0
			leftFarEnd = CGPoint(x: paths.leftP3.x + fitW * sign, y: paths.leftP3.y)
			rightFarEnd = CGPoint(x: paths.rightP3.x + fitW * sign, y: paths.rightP3.y)

			mainAxisDist = abs(paths.leftP3.x - paths.leftP0.x)
			winMainSize = frame.width
			mainNorm = (direction == .right) ? normalizedX : (1.0 - normalizedX)
			crossNorm = normalizedY
		}

		// --- 共通ロジック: 拡張カーブ上の座標計算 ---

		// 延長比率: P3→farEnd / P0→P3
		let farEndAxisDist = isVertical
			? abs(leftFarEnd.y - paths.leftP3.y)
			: abs(leftFarEnd.x - paths.leftP3.x)
		let extensionT = farEndAxisDist / max(mainAxisDist, 1.0)
		let tMax = 1.0 + extensionT

		// カーブ全長に対するウインドウサイズの比率
		let winT = min(winMainSize / max(mainAxisDist, 1.0), 0.95)

		// 行/列ごとの移動進行度 (trailing辺ほど遅延)
		let stretchAmount = stretchPower * widthProgress * (1.0 - mainNorm)
		let rowSlide = pow(slideProgress, 1.0 + stretchAmount)

		// 拡張カーブ上のパラメータ t
		// 初期状態 (rowSlide=0): t = mainNorm * winT (ウインドウサイズ分に展開)
		// 完了時 (rowSlide=1): t = tEnd
		//   leading辺 (mainNorm=1): tMax (far edge) に到達
		//   trailing辺 (mainNorm=0): 1.0 (P3 = near edge) に到達
		let initialT = mainNorm * winT
		let tEnd = lerp(1.0, tMax, mainNorm)
		let t = lerp(initialT, tEnd, rowSlide)

		// 拡張カーブ上の2端点 (t>1 で P3→farEnd に自然に延長)
		let pt1 = extendedCurvePoint(
			paths.leftP0, paths.leftP1, paths.leftP2, paths.leftP3,
			farEnd: leftFarEnd, t: t, tMax: tMax
		)
		let pt2 = extendedCurvePoint(
			paths.rightP0, paths.rightP1, paths.rightP2, paths.rightP3,
			farEnd: rightFarEnd, t: t, tMax: tMax
		)

		// カーブ上の座標: crossNorm で2本のカーブ間を補間
		let curveX = lerp(pt1.x, pt2.x, crossNorm)
		let curveY = lerp(pt1.y, pt2.y, crossNorm)

		// widthProgress で元の矩形 → カーブ上に遷移
		return CGPoint(
			x: lerp(origX, curveX, widthProgress),
			y: lerp(origY, curveY, widthProgress)
		)
	}
}
