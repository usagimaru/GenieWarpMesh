//
//  DebugOverlayWindow.swift
//  GenieWarpMesh
//
//  © 2026 usagimaru.
//  ジニーワープエフェクトのベジェカーブ軌跡とメッシュワイヤーフレームを描画する全画面透過ウインドウ。
//

import Cocoa

// MARK: - DebugOverlayWindow

/// ジニーワープのデバッグデータを可視化する透過フルスクリーンオーバーレイウインドウ。
///
/// メインスクリーン全体を覆い、高いウインドウレベルに配置される。全てのマウスイベントを無視し、ユーザーによる移動もできない。
/// ``GenieDebugOverlay`` に準拠しており、``GenieEffect`` からカーブおよびメッシュデータを直接受信できる。
/// ``GenieEffect/debugOverlayReceiver`` にインスタンスを設定してオーバーレイを有効化する。
/// `orderFront` の呼び出しや画面ジオメトリ変更時の ``fitToScreen()`` 呼び出しは呼び出し元の責務。
public class DebugOverlayWindow: NSWindow {

	private let overlayView = DebugOverlayView()

	/// メインスクリーンのサイズでデバッグオーバーレイウインドウを生成する。
	public init() {
		let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
		super.init(
			contentRect: screenFrame,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)

		// 透明・マウスイベント透過
		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		ignoresMouseEvents = true
		level = .screenSaver  // 最前面に近いレベル
		collectionBehavior = [.moveToActiveSpace]
		animationBehavior = .none
		isMovable = false
		isMovableByWindowBackground = false

		overlayView.frame = screenFrame
		overlayView.autoresizingMask = [.width, .height]
		contentView = overlayView
	}

	// ドラッグによるウインドウ移動を無効化
	override public func performDrag(with event: NSEvent) {}

	// MARK: - Public API

	/// オーバーレイ上の全てのカーブ、フレーム、メッシュ描画をクリアする。
	public func clearCurves() {
		overlayView.leftCurve = nil
		overlayView.rightCurve = nil
		overlayView.sourceFrame = nil
		overlayView.targetFrame = nil
		overlayView.fitRect = nil
		overlayView.leftExtensionEnd = nil
		overlayView.rightExtensionEnd = nil
		overlayView.correctedLeftCurve = nil
		overlayView.correctedRightCurve = nil
		overlayView.correctedLeftExtensionEnd = nil
		overlayView.correctedRightExtensionEnd = nil
		overlayView.correctedSourceFrame = nil
		overlayView.meshEdgePoints = nil
		forceDisplay()
	}

	/// 現在のメインスクリーンサイズに合わせてオーバーレイをリサイズする。
	public func fitToScreen() {
		guard let screen = NSScreen.main else { return }
		setFrame(screen.frame, display: true)
	}

	/// ウインドウサーバーにオーバーレイの再合成を強制する。
	///
	/// タイトルバーのドラッグ中はウインドウサーバーが通常の `display()` を
	/// スキップすることがある。1pt 縮小→復元というリサイズにより、
	/// 確実に再合成がトリガーされる。
	private func forceDisplay() {
		let f = frame
		setFrame(CGRect(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height - 1), display: false)
		setFrame(f, display: true)
	}
}

// MARK: - GenieDebugOverlay 準拠

extension DebugOverlayWindow: GenieDebugOverlay {

	public func receiveCurveGuideData(leftCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint),
									  rightCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint),
									  sourceFrame: CGRect,
									  targetFrame: CGRect,
									  fitRect: CGRect?,
									  leftExtensionEnd: CGPoint?,
									  rightExtensionEnd: CGPoint?,
									  correctedData: CorrectedCurveData?)
	{
		overlayView.leftCurve = leftCurve
		overlayView.rightCurve = rightCurve
		overlayView.sourceFrame = sourceFrame
		overlayView.targetFrame = targetFrame
		overlayView.fitRect = fitRect
		overlayView.leftExtensionEnd = leftExtensionEnd
		overlayView.rightExtensionEnd = rightExtensionEnd
		overlayView.correctedLeftCurve = correctedData?.leftCurve
		overlayView.correctedRightCurve = correctedData?.rightCurve
		overlayView.correctedLeftExtensionEnd = correctedData.map { $0.leftExtensionEnd }
		overlayView.correctedRightExtensionEnd = correctedData.map { $0.rightExtensionEnd }
		overlayView.correctedSourceFrame = correctedData?.sourceFrame
		forceDisplay()
	}
	
	public func receiveMeshEdgePoints(_ points: [CGPoint],
									  gridWidth: Int,
									  gridHeight: Int,
									  screenHeight: CGFloat)
	{
		overlayView.meshEdgePoints = points
		overlayView.meshGridWidth = gridWidth
		overlayView.meshGridHeight = gridHeight
		overlayView.meshScreenHeight = screenHeight
		forceDisplay()
	}

	public func clearMeshEdgePoints() {
		overlayView.meshEdgePoints = nil
		forceDisplay()
	}
}

// MARK: - DebugOverlayView

/// ベジェカーブパス、フレームワイヤーフレーム、メッシュ外枠を描画する内部ビュー。
/// `GenieEffect` から受信する座標は CG座標系 (左上原点) であり、
/// 描画時に Cocoa座標系 (左下原点) に変換される。
class DebugOverlayView: NSView {

	// 通常カーブの制御点 (CG座標系)
	var leftCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint)?
	var rightCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint)?

	// フレーム矩形 (Cocoa座標系)
	var sourceFrame: CGRect?
	var targetFrame: CGRect?

	/// ターゲット内の scale-to-fit 矩形 (CG座標系)
	var fitRect: CGRect?

	/// P3 からターゲット far edge への延長線終端 (CG座標系)
	var leftExtensionEnd: CGPoint?
	var rightExtensionEnd: CGPoint?

	/// 補正カーブの制御点 (CG座標系)。近接補正が有効な場合のみ設定される。
	var correctedLeftCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint)?
	var correctedRightCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint)?
	var correctedLeftExtensionEnd: CGPoint?
	var correctedRightExtensionEnd: CGPoint?
	/// 補正済みソースフレーム (Cocoa座標系)
	var correctedSourceFrame: CGRect?

	/// アニメーション中のメッシュ外枠交点 (CG座標系)
	var meshEdgePoints: [CGPoint]?
	var meshGridWidth: Int = 0
	var meshGridHeight: Int = 0
	var meshScreenHeight: CGFloat = 0

	override func draw(_ dirtyRect: NSRect) {
		super.draw(dirtyRect)

		guard let context = NSGraphicsContext.current?.cgContext else { return }
		let screenHeight = bounds.height

		// ソースフレーム (ワイヤーフレーム)
		if let sf = sourceFrame {
			context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.7).cgColor)
			context.setLineWidth(1.0)
			context.setLineDash(phase: 0, lengths: [4, 4])
			context.stroke(sf)
			context.setLineDash(phase: 0, lengths: [])
		}

		// ターゲットフレーム (ワイヤーフレーム)
		if let tf = targetFrame {
			context.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.7).cgColor)
			context.setLineWidth(1.0)
			context.setLineDash(phase: 0, lengths: [4, 4])
			context.stroke(tf)
			context.setLineDash(phase: 0, lengths: [])
		}

		// scale-to-fit 矩形 (CG座標→Cocoa座標変換)
		if let fr = fitRect {
			let cocoaFitRect = CGRect(
				x: fr.origin.x,
				y: screenHeight - fr.origin.y - fr.height,
				width: fr.width,
				height: fr.height
			)
			context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(0.7).cgColor)
			context.setLineWidth(1.0)
			context.setLineDash(phase: 0, lengths: [2, 2])
			context.stroke(cocoaFitRect)
			context.setLineDash(phase: 0, lengths: [])
		}

		// 補正カーブが存在する場合、通常カーブを点線化
		let hasCorrected = correctedLeftCurve != nil

		// 左辺カーブ (CG座標→Cocoa座標変換)
		if let lc = leftCurve {
			drawBezierCurve(
				context: context,
				p0: cgToCocoa(lc.p0, screenHeight: screenHeight),
				p1: cgToCocoa(lc.p1, screenHeight: screenHeight),
				p2: cgToCocoa(lc.p2, screenHeight: screenHeight),
				p3: cgToCocoa(lc.p3, screenHeight: screenHeight),
				color: NSColor.systemCyan.withAlphaComponent(hasCorrected ? 0.4 : 0.8),
				dashed: hasCorrected
			)
		}

		// 右辺カーブ (CG座標→Cocoa座標変換)
		if let rc = rightCurve {
			drawBezierCurve(
				context: context,
				p0: cgToCocoa(rc.p0, screenHeight: screenHeight),
				p1: cgToCocoa(rc.p1, screenHeight: screenHeight),
				p2: cgToCocoa(rc.p2, screenHeight: screenHeight),
				p3: cgToCocoa(rc.p3, screenHeight: screenHeight),
				color: NSColor.systemGreen.withAlphaComponent(hasCorrected ? 0.4 : 0.8),
				dashed: hasCorrected
			)
		}

		// 制御点の描画
		if let lc = leftCurve {
			drawControlPoints(
				context: context,
				p0: cgToCocoa(lc.p0, screenHeight: screenHeight),
				p1: cgToCocoa(lc.p1, screenHeight: screenHeight),
				p2: cgToCocoa(lc.p2, screenHeight: screenHeight),
				p3: cgToCocoa(lc.p3, screenHeight: screenHeight),
				color: NSColor.systemCyan.withAlphaComponent(hasCorrected ? 0.4 : 1.0)
			)
		}
		if let rc = rightCurve {
			drawControlPoints(
				context: context,
				p0: cgToCocoa(rc.p0, screenHeight: screenHeight),
				p1: cgToCocoa(rc.p1, screenHeight: screenHeight),
				p2: cgToCocoa(rc.p2, screenHeight: screenHeight),
				p3: cgToCocoa(rc.p3, screenHeight: screenHeight),
				color: NSColor.systemGreen.withAlphaComponent(hasCorrected ? 0.4 : 1.0)
			)
		}

		// P3 → far edge への延長線の描画
		if let lc = leftCurve, let lEnd = leftExtensionEnd {
			drawExtensionLine(
				context: context,
				from: cgToCocoa(lc.p3, screenHeight: screenHeight),
				to: cgToCocoa(lEnd, screenHeight: screenHeight),
				color: NSColor.systemCyan.withAlphaComponent(hasCorrected ? 0.2 : 0.5)
			)
		}
		if let rc = rightCurve, let rEnd = rightExtensionEnd {
			drawExtensionLine(
				context: context,
				from: cgToCocoa(rc.p3, screenHeight: screenHeight),
				to: cgToCocoa(rEnd, screenHeight: screenHeight),
				color: NSColor.systemGreen.withAlphaComponent(hasCorrected ? 0.2 : 0.5)
			)
		}

		// 補正用ソースフレーム (Cocoa座標系なのでそのまま描画)
		if let csf = correctedSourceFrame {
			context.setStrokeColor(NSColor.systemPink.withAlphaComponent(0.5).cgColor)
			context.setLineWidth(1.0)
			context.setLineDash(phase: 0, lengths: [4, 4])
			context.stroke(csf)
			context.setLineDash(phase: 0, lengths: [])
		}

		// 補正用左辺カーブ
		if let clc = correctedLeftCurve {
			drawBezierCurve(
				context: context,
				p0: cgToCocoa(clc.p0, screenHeight: screenHeight),
				p1: cgToCocoa(clc.p1, screenHeight: screenHeight),
				p2: cgToCocoa(clc.p2, screenHeight: screenHeight),
				p3: cgToCocoa(clc.p3, screenHeight: screenHeight),
				color: NSColor.systemPink.withAlphaComponent(0.6)
			)
		}

		// 補正用右辺カーブ
		if let crc = correctedRightCurve {
			drawBezierCurve(
				context: context,
				p0: cgToCocoa(crc.p0, screenHeight: screenHeight),
				p1: cgToCocoa(crc.p1, screenHeight: screenHeight),
				p2: cgToCocoa(crc.p2, screenHeight: screenHeight),
				p3: cgToCocoa(crc.p3, screenHeight: screenHeight),
				color: NSColor.systemPurple.withAlphaComponent(0.6)
			)
		}

		// 補正用制御点
		if let clc = correctedLeftCurve {
			drawControlPoints(
				context: context,
				p0: cgToCocoa(clc.p0, screenHeight: screenHeight),
				p1: cgToCocoa(clc.p1, screenHeight: screenHeight),
				p2: cgToCocoa(clc.p2, screenHeight: screenHeight),
				p3: cgToCocoa(clc.p3, screenHeight: screenHeight),
				color: NSColor.systemPink
			)
		}
		if let crc = correctedRightCurve {
			drawControlPoints(
				context: context,
				p0: cgToCocoa(crc.p0, screenHeight: screenHeight),
				p1: cgToCocoa(crc.p1, screenHeight: screenHeight),
				p2: cgToCocoa(crc.p2, screenHeight: screenHeight),
				p3: cgToCocoa(crc.p3, screenHeight: screenHeight),
				color: NSColor.systemPurple
			)
		}

		// 補正用延長線
		if let clc = correctedLeftCurve, let clEnd = correctedLeftExtensionEnd {
			drawExtensionLine(
				context: context,
				from: cgToCocoa(clc.p3, screenHeight: screenHeight),
				to: cgToCocoa(clEnd, screenHeight: screenHeight),
				color: NSColor.systemPink.withAlphaComponent(0.4)
			)
		}
		if let crc = correctedRightCurve, let crEnd = correctedRightExtensionEnd {
			drawExtensionLine(
				context: context,
				from: cgToCocoa(crc.p3, screenHeight: screenHeight),
				to: cgToCocoa(crEnd, screenHeight: screenHeight),
				color: NSColor.systemPurple.withAlphaComponent(0.4)
			)
		}

		// メッシュ外枠交点の描画
		if let edgePoints = meshEdgePoints, !edgePoints.isEmpty {
			let sh = meshScreenHeight
			let gw = meshGridWidth
			let gh = meshGridHeight

			// メッシュ外枠の全交点を行列順に再構築
			// GenieEffect から送られる順序:
			//   1) 上辺・下辺: col=0..<gw の各 col につき (row=0, row=gh-1) → gw*2 個
			//   2) 左辺・右辺 (角を除く): row=1..<(gh-1) の各 row につき (col=0, col=gw-1) → (gh-2)*2 個
			// これを辺ごとの配列に分離する

			var topEdge = [CGPoint]()    // row=0, col=0..<gw
			var bottomEdge = [CGPoint]() // row=gh-1, col=0..<gw
			var leftEdge = [CGPoint]()   // col=0, row=1..<(gh-1)
			var rightEdge = [CGPoint]()  // col=gw-1, row=1..<(gh-1)

			let tbCount = gw * 2
			for col in 0..<gw {
				let baseIdx = col * 2
				if baseIdx < edgePoints.count {
					topEdge.append(edgePoints[baseIdx])
				}
				if baseIdx + 1 < edgePoints.count {
					bottomEdge.append(edgePoints[baseIdx + 1])
				}
			}
			for row in 1..<(gh - 1) {
				let baseIdx = tbCount + (row - 1) * 2
				if baseIdx < edgePoints.count {
					leftEdge.append(edgePoints[baseIdx])
				}
				if baseIdx + 1 < edgePoints.count {
					rightEdge.append(edgePoints[baseIdx + 1])
				}
			}

			// 外枠の辺を線でつなぐ
			let edgeColor = NSColor.systemYellow.withAlphaComponent(0.5)
			context.setStrokeColor(edgeColor.cgColor)
			context.setLineWidth(0.5)

			// 上辺
			if topEdge.count >= 2 {
				let path = CGMutablePath()
				path.move(to: cgToCocoa(topEdge[0], screenHeight: sh))
				for i in 1..<topEdge.count {
					path.addLine(to: cgToCocoa(topEdge[i], screenHeight: sh))
				}
				context.addPath(path)
				context.strokePath()
			}
			// 下辺
			if bottomEdge.count >= 2 {
				let path = CGMutablePath()
				path.move(to: cgToCocoa(bottomEdge[0], screenHeight: sh))
				for i in 1..<bottomEdge.count {
					path.addLine(to: cgToCocoa(bottomEdge[i], screenHeight: sh))
				}
				context.addPath(path)
				context.strokePath()
			}
			// 左辺 (topEdge[0] → leftEdge → bottomEdge[0])
			if !leftEdge.isEmpty, let tl = topEdge.first, let bl = bottomEdge.first {
				let path = CGMutablePath()
				path.move(to: cgToCocoa(tl, screenHeight: sh))
				for pt in leftEdge {
					path.addLine(to: cgToCocoa(pt, screenHeight: sh))
				}
				path.addLine(to: cgToCocoa(bl, screenHeight: sh))
				context.addPath(path)
				context.strokePath()
			}
			// 右辺 (topEdge[last] → rightEdge → bottomEdge[last])
			if !rightEdge.isEmpty, let tr = topEdge.last, let br = bottomEdge.last {
				let path = CGMutablePath()
				path.move(to: cgToCocoa(tr, screenHeight: sh))
				for pt in rightEdge {
					path.addLine(to: cgToCocoa(pt, screenHeight: sh))
				}
				path.addLine(to: cgToCocoa(br, screenHeight: sh))
				context.addPath(path)
				context.strokePath()
			}

			// 全交点にドットを描画
			let dotRadius: CGFloat = 2.0
			let cornerRadius: CGFloat = 4.0
			let dotColor = NSColor.systemYellow
			context.setFillColor(dotColor.cgColor)

			let allEdge = topEdge + bottomEdge + leftEdge + rightEdge
			// 4隅 = topEdge.first, topEdge.last, bottomEdge.first, bottomEdge.last
			let corners: Set<Int> = [
				0,                      // topEdge[0]
				topEdge.count - 1,      // topEdge[last]
				topEdge.count,          // bottomEdge[0]
				topEdge.count + bottomEdge.count - 1, // bottomEdge[last]
			]

			for (i, pt) in allEdge.enumerated() {
				let cocoaPt = cgToCocoa(pt, screenHeight: sh)
				let r = corners.contains(i) ? cornerRadius : dotRadius
				let rect = CGRect(x: cocoaPt.x - r, y: cocoaPt.y - r,
								  width: r * 2, height: r * 2)
				context.fillEllipse(in: rect)
			}

			// 4隅にラベル
			let cornerLabels: [(Int, String)] = [
				(0, "TL"),
				(topEdge.count - 1, "TR"),
				(topEdge.count, "BL"),
				(topEdge.count + bottomEdge.count - 1, "BR"),
			]
			let labelAttrs: [NSAttributedString.Key: Any] = [
				.font: NSFont.systemFont(ofSize: 10, weight: .bold),
				.foregroundColor: dotColor,
			]
			for (idx, label) in cornerLabels {
				if idx < allEdge.count {
					let cocoaPt = cgToCocoa(allEdge[idx], screenHeight: sh)
					let str = NSAttributedString(string: label, attributes: labelAttrs)
					str.draw(at: CGPoint(x: cocoaPt.x + cornerRadius + 2, y: cocoaPt.y - 6))
				}
			}
		}
	}

	// MARK: - 描画ヘルパー

	/// CG座標 (左上原点) → Cocoa座標 (左下原点) に変換する。
	private func cgToCocoa(_ point: CGPoint, screenHeight: CGFloat) -> CGPoint {
		return CGPoint(x: point.x, y: screenHeight - point.y)
	}
	
	/// 3次ベジェカーブを描画する。P0→P3 を制御点 P1, P2 で結ぶ。
	private func drawBezierCurve(context: CGContext,
								 p0: CGPoint,
								 p1: CGPoint,
								 p2: CGPoint,
								 p3: CGPoint,
								 color: NSColor,
								 dashed: Bool = false)
	{
		let path = CGMutablePath()
		path.move(to: p0)
		path.addCurve(to: p3, control1: p1, control2: p2)

		context.setStrokeColor(color.cgColor)
		context.setLineWidth(2.0)
		if dashed {
			context.setLineDash(phase: 0, lengths: [6, 4])
		}
		context.addPath(path)
		context.strokePath()
		if dashed {
			context.setLineDash(phase: 0, lengths: [])
		}
	}
	
	/// 制御点ハンドルと制御線を描画する。
	private func drawControlPoints(context: CGContext,
								   p0: CGPoint,
								   p1: CGPoint,
								   p2: CGPoint,
								   p3: CGPoint,
								   color: NSColor)
	{
		// 制御線 (P0→P1, P2→P3)
		context.setStrokeColor(color.withAlphaComponent(0.3).cgColor)
		context.setLineWidth(1.0)
		context.setLineDash(phase: 0, lengths: [2, 2])
		context.move(to: p0)
		context.addLine(to: p1)
		context.strokePath()
		context.move(to: p2)
		context.addLine(to: p3)
		context.strokePath()
		context.setLineDash(phase: 0, lengths: [])

		// 端点 (P0, P3) — 塗りつぶし丸
		let endPointRadius: CGFloat = 4.0
		for pt in [p0, p3] {
			let rect = CGRect(
				x: pt.x - endPointRadius,
				y: pt.y - endPointRadius,
				width: endPointRadius * 2,
				height: endPointRadius * 2
			)
			context.setFillColor(color.cgColor)
			context.fillEllipse(in: rect)
		}

		// 制御点 (P1, P2) — 中抜き丸
		let controlRadius: CGFloat = 3.0
		for pt in [p1, p2] {
			let rect = CGRect(
				x: pt.x - controlRadius,
				y: pt.y - controlRadius,
				width: controlRadius * 2,
				height: controlRadius * 2
			)
			context.setStrokeColor(color.cgColor)
			context.setLineWidth(1.5)
			context.strokeEllipse(in: rect)
		}
	}

	/// P3 → far edge への延長線を描画する（破線 + 終端ドット）。
	private func drawExtensionLine(context: CGContext,
								   from start: CGPoint,
								   to end: CGPoint,
								   color: NSColor)
	{
		// 破線で延長線を描画
		context.setStrokeColor(color.cgColor)
		context.setLineWidth(1.5)
		context.setLineDash(phase: 0, lengths: [6, 4])
		context.move(to: start)
		context.addLine(to: end)
		context.strokePath()
		context.setLineDash(phase: 0, lengths: [])

		// 終端にドットを描画
		let dotRadius: CGFloat = 3.0
		let rect = CGRect(
			x: end.x - dotRadius,
			y: end.y - dotRadius,
			width: dotRadius * 2,
			height: dotRadius * 2
		)
		context.setFillColor(color.cgColor)
		context.fillEllipse(in: rect)
	}
}
