//
//  ControlPanelViewController.swift
//  GenieWarpMesh
//
//  Created by usagimaru on 2026/03/20.
//  © 2026 usagimaru.
//

import Cocoa
import QuartzCore
import GenieWarpMesh
import CGSPrivate


// MARK: - FlippedClipView

/// NSScrollView の contentView を上寄せにするための Flipped ClipView
class FlippedClipView: NSClipView {
	override var isFlipped: Bool { true }
}


// MARK: - ControlPanelViewController

class ControlPanelViewController: NSViewController {

	private let genieEffect = GenieEffect()
	private var isMinimized = false
	private var minimizeDirection: GenieDirection = .bottom
	private var directionMode: GenieDirection = .auto
	private var targetPanelController: TargetPanelController!
	private var debugOverlayWindow: DebugOverlayWindow?

	/// ドラッグ中のリアルタイム更新用 DisplayLink
	private var displayLink: CADisplayLink?
	/// 前フレームのウインドウフレーム（変化検出用）
	private var lastWindowFrame: CGRect = .zero
	private var lastTargetFrame: CGRect = .zero

	// UI要素
	private var durationSlider: NSSlider!
	private var durationLabel: NSTextField!
	private var minimizeButton: NSButton!
	private var debugCheckbox: NSButton!
	private var easingPopUp: NSPopUpButton!
	private var retreatEasingPopUp: NSPopUpButton!
	private var directionModePopUp: NSPopUpButton!
	private var skipCutoffCheckbox: NSButton!

	// パラメータスライダーの値ラベル
	private var paramLabels: [String: NSTextField] = [:]
	// パラメータスライダーの参照
	private var paramSliders: [String: NSSlider] = [:]
	// パラメータステッパーの参照
	private var paramSteppers: [String: NSStepper] = [:]
	// パラメータテキストフィールドの参照
	private var paramTextFields: [String: NSTextField] = [:]
	// デフォルト値の辞書
	private var paramDefaults: [String: (value: Double, format: String)] = [:]

	// レイアウト定数
	private let paramLabelWidth: CGFloat = 120

	// UserDefaults キー
	private static let keyDuration = "genie_duration"
	private static let keyDebugOverlay = "genie_debugOverlay"
	private static let keyWindowFrame = "genie_windowFrame"
	private static let keyTargetFrame = "genie_targetFrame"
	private static let keyEasingType = "genie_easingType"
	private static let keyRetreatEasingType = "genie_retreatEasingType"
	private static let keyDirectionMode = "genie_directionMode"
	private static let keyMinimizeRawTStart = "genie_minimizeRawTStart"
	private static let keyMinimizeRawTEnd = "genie_minimizeRawTEnd"
	private static let keyRestoreRawTStart = "genie_restoreRawTStart"
	private static let keyRestoreRawTEnd = "genie_restoreRawTEnd"
	private static let keySkipCutoffOnRetreat = "genie_skipCutoffOnRetreat"

	deinit {
		stopDisplayLinkTracking()
		NotificationCenter.default.removeObserver(self)
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		setupUI()
		targetPanelController = TargetPanelController()
	}

	private var hasShownTargetPanel = false

	override func viewDidAppear() {
		super.viewDidAppear()
		guard !hasShownTargetPanel else { return }
		hasShownTargetPanel = true

		// ウインドウタイトル
		view.window?.title = String(localized: "Genie Effect Demo")
		view.window?.contentMinSize = CGSize(width: 250, height: 250)
		view.window?.isRestorable = false

		// ウインドウフレームの復元
		if let window = view.window,
		   let savedFrame = UserDefaults.standard.string(forKey: Self.keyWindowFrame) {
			window.setFrame(NSRectFromString(savedFrame), display: true)
		}

		// ターゲットパネルの配置（保存位置があれば復元）
		if let savedTarget = UserDefaults.standard.string(forKey: Self.keyTargetFrame) {
			let frame = NSRectFromString(savedTarget)
			targetPanelController.panel.setFrame(frame, display: true)
			targetPanelController.panel.orderFront(nil)
		} else if let windowFrame = view.window?.frame {
			targetPanelController.show(relativeTo: windowFrame)
		}

		// デバッグオーバーレイの復元
		if debugCheckbox.state == .on {
			showWireframeOverlay(debugCheckbox)
		}

		// ウインドウ移動・リサイズ時にフレームを保存＋オーバーレイ更新
		NotificationCenter.default.addObserver(self, selector: #selector(windowDidMoveOrResize(_:)),
											   name: NSWindow.didMoveNotification, object: view.window)
		NotificationCenter.default.addObserver(self, selector: #selector(windowDidMoveOrResize(_:)),
											   name: NSWindow.didResizeNotification, object: view.window)

		// ターゲットパネル移動・リサイズ時
		NotificationCenter.default.addObserver(self, selector: #selector(targetDidMoveOrResize(_:)),
											   name: NSWindow.didMoveNotification, object: targetPanelController.panel)
		NotificationCenter.default.addObserver(self, selector: #selector(targetDidMoveOrResize(_:)),
											   name: NSWindow.didResizeNotification, object: targetPanelController.panel)

	}

	// MARK: - CADisplayLink Tracking

	/// CADisplayLink を開始してフレーム毎にウインドウ位置の変化を検出する。
	/// .common RunLoopモードに追加することで .eventTracking 中（タイトルバードラッグ中）も動作する。
	private func startDisplayLinkTracking() {
		guard displayLink == nil else { return }
		// 初回フレームで必ず変化を検出するよう .zero で初期化
		lastWindowFrame = .zero
		lastTargetFrame = .zero

		guard let screen = view.window?.screen ?? NSScreen.main else { return }
		let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
		link.add(to: .main, forMode: .common)
		displayLink = link
	}

	/// CADisplayLink を停止する
	private func stopDisplayLinkTracking() {
		displayLink?.invalidate()
		displayLink = nil
	}

	/// CGSGetWindowBounds でウインドウの実座標を取得する（CG座標→Cocoa座標変換済み）。
	/// タイトルバードラッグ中でもウインドウサーバーからリアルタイムの値が返る。
	private func windowFrameFromCGS(_ windowNumber: Int) -> CGRect? {
		let cid = CGSMainConnectionID()
		var cgBounds = CGRect.zero
		let err = CGSGetWindowBounds(cid, CGSWindowID(windowNumber), &cgBounds)
		guard err == .success else { return nil }

		// CG座標系 (左上原点) → Cocoa座標系 (左下原点)
		guard let screenHeight = NSScreen.main?.frame.height else { return nil }
		let cocoaY = screenHeight - cgBounds.origin.y - cgBounds.height
		return CGRect(x: cgBounds.origin.x, y: cocoaY, width: cgBounds.width, height: cgBounds.height)
	}

	@objc private func displayLinkFired(_ link: CADisplayLink) {
		guard debugOverlayWindow != nil,
			  let window = view.window else { return }

		// CGSGetWindowBounds でウインドウサーバーから直接位置を取得
		let currentWindowFrame = windowFrameFromCGS(window.windowNumber) ?? window.frame
		let currentTargetFrame = windowFrameFromCGS(targetPanelController.panel.windowNumber) ?? targetPanelController.panel.frame

		let windowMoved = currentWindowFrame != lastWindowFrame
		let targetMoved = currentTargetFrame != lastTargetFrame

		if windowMoved { lastWindowFrame = currentWindowFrame }
		if targetMoved { lastTargetFrame = currentTargetFrame }

		if windowMoved || targetMoved {
			refreshDebugOverlay()
		}
	}

	@objc private func windowDidMoveOrResize(_ notification: Notification) {
		saveWindowFrames()
		refreshDebugOverlay()
	}

	@objc private func targetDidMoveOrResize(_ notification: Notification) {
		saveTargetFrame()
		refreshDebugOverlay()
	}

	private func saveWindowFrames() {
		if let frame = view.window?.frame {
			UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.keyWindowFrame)
		}
	}

	// MARK: - UI Setup

	/// パラメータスライダー定義
	private struct ParamDef {
		let key: String
		let label: String
		let min: Double
		let max: Double
		let initial: Double
		let format: String
		let description: String?

		init(key: String, label: String, min: Double, max: Double, initial: Double, format: String, description: String? = nil) {
			self.key = key
			self.label = label
			self.min = min
			self.max = max
			self.initial = initial
			self.format = format
			self.description = description
		}
	}

	private func setupUI() {
		setupBottomBar()
		let stackView = setupScrollableStackView()

		restoreSavedParameters()

		setupDurationSection(in: stackView)
		setupDirectionSection(in: stackView)
		addSpacer(to: stackView, height: 10)
		setupPhaseControlSection(in: stackView)
		setupParameterSliders(in: stackView)
		setupEasingSection(in: stackView)
		addSpacer(to: stackView, height: 4)
		setupCurveShapeSection(in: stackView)
		addSpacer(to: stackView, height: 4)
		setupRetreatSection(in: stackView)
		addSpacer(to: stackView, height: 4)
		setupMeshResolutionSection(in: stackView)
	}

	// MARK: - UI Setup: Bottom Bar

	private func setupBottomBar() {
		minimizeButton = NSButton(title: String(localized: "Start Genie"), target: self, action: #selector(performGenie(_:)))
		minimizeButton.bezelStyle = .rounded
		minimizeButton.controlSize = .large
		minimizeButton.font = .systemFont(ofSize: 14, weight: .medium)
		minimizeButton.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(minimizeButton)

		debugCheckbox = NSButton(checkboxWithTitle: String(localized: "Show Orbit"), target: self, action: #selector(showWireframeOverlay(_:)))
		debugCheckbox.controlSize = .small
		let savedDebug = UserDefaults.standard.bool(forKey: Self.keyDebugOverlay)
		debugCheckbox.state = savedDebug ? .on : .off
		debugCheckbox.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(debugCheckbox)

		let resetAllButton = NSButton(title: String(localized: "Reset All"), target: self, action: #selector(resetAllParams(_:)))
		resetAllButton.bezelStyle = .rounded
		resetAllButton.controlSize = .small
		resetAllButton.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(resetAllButton)

		NSLayoutConstraint.activate([
			minimizeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
			minimizeButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
			debugCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
			debugCheckbox.centerYAnchor.constraint(equalTo: minimizeButton.centerYAnchor),
			resetAllButton.leadingAnchor.constraint(equalTo: debugCheckbox.trailingAnchor, constant: 40),
			resetAllButton.centerYAnchor.constraint(equalTo: debugCheckbox.centerYAnchor),
		])
	}

	// MARK: - UI Setup: Scrollable Stack View

	private func setupScrollableStackView() -> NSStackView {
		let scrollView = NSScrollView()
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = false
		scrollView.translatesAutoresizingMaskIntoConstraints = false

		let flippedClipView = FlippedClipView()
		flippedClipView.drawsBackground = false
		scrollView.contentView = flippedClipView

		view.addSubview(scrollView)

		NSLayoutConstraint.activate([
			scrollView.topAnchor.constraint(equalTo: view.topAnchor),
			scrollView.bottomAnchor.constraint(equalTo: minimizeButton.topAnchor, constant: -8),
			scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
		])

		let stackView = NSStackView()
		stackView.orientation = .vertical
		stackView.alignment = .leading
		stackView.spacing = 6
		stackView.translatesAutoresizingMaskIntoConstraints = false
		stackView.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 20, right: 20)

		scrollView.documentView = stackView

		NSLayoutConstraint.activate([
			stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
			stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
			stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
		])

		return stackView
	}

	// MARK: - UI Setup: Restore Saved Parameters

	/// UserDefaults からパラメータを復元する
	private func restoreSavedParameters() {
		// 吸い込み方向
		if UserDefaults.standard.object(forKey: Self.keyDirectionMode) != nil,
		   let restoredMode = GenieDirection.fromPersistenceValue(UserDefaults.standard.integer(forKey: Self.keyDirectionMode)) {
			directionMode = restoredMode
		}

		// rawT カットオフ
		if UserDefaults.standard.object(forKey: Self.keyMinimizeRawTStart) != nil {
			genieEffect.minimizeRawTStart = CGFloat(UserDefaults.standard.double(forKey: Self.keyMinimizeRawTStart))
		}
		if UserDefaults.standard.object(forKey: Self.keyMinimizeRawTEnd) != nil {
			genieEffect.minimizeRawTEnd = CGFloat(UserDefaults.standard.double(forKey: Self.keyMinimizeRawTEnd))
		}
		if UserDefaults.standard.object(forKey: Self.keyRestoreRawTStart) != nil {
			genieEffect.restoreRawTStart = CGFloat(UserDefaults.standard.double(forKey: Self.keyRestoreRawTStart))
		}
		if UserDefaults.standard.object(forKey: Self.keyRestoreRawTEnd) != nil {
			genieEffect.restoreRawTEnd = CGFloat(UserDefaults.standard.double(forKey: Self.keyRestoreRawTEnd))
		}
		if UserDefaults.standard.object(forKey: Self.keySkipCutoffOnRetreat) != nil {
			genieEffect.skipCutoffOnRetreat = UserDefaults.standard.bool(forKey: Self.keySkipCutoffOnRetreat)
		}

		// イージング
		if UserDefaults.standard.object(forKey: Self.keyEasingType) != nil,
		   let restoredType = EasingType(rawValue: UserDefaults.standard.integer(forKey: Self.keyEasingType)) {
			genieEffect.easingType = restoredType
		}

		// 退避イージング
		if UserDefaults.standard.object(forKey: Self.keyRetreatEasingType) != nil,
		   let restoredType = EasingType(rawValue: UserDefaults.standard.integer(forKey: Self.keyRetreatEasingType)) {
			genieEffect.retreatEasingType = restoredType
		}
	}

	// MARK: - UI Setup: Duration

	private func setupDurationSection(in stackView: NSStackView) {
		let savedDuration = UserDefaults.standard.double(forKey: Self.keyDuration)
		let initialDuration = savedDuration > 0 ? savedDuration : 1.0

		let durationRow = makeSliderRow(
			label: String(localized: "Length"),
			value: initialDuration, min: 0.15, max: 5.0,
			format: "%.2fs",
			action: #selector(durationChanged(_:)),
			identifier: "duration",
			defaultValue: 1.0
		)
		durationSlider = durationRow.slider
		durationLabel = durationRow.valueLabel
		paramLabels["duration"] = durationRow.valueLabel
		stackView.addArrangedSubview(durationRow.row)
		updateValueLabelWeight(key: "duration", currentValue: initialDuration)
	}

	// MARK: - UI Setup: Direction

	private func setupDirectionSection(in stackView: NSStackView) {
		let directionRow = makePopUpRow(
			label: String(localized: "Target"),
			items: GenieDirection.allCases.map { $0.displayName },
			selectedIndex: GenieDirection.allCases.firstIndex(of: directionMode) ?? 0,
			defaultIndex: 0,
			action: #selector(directionModeChanged(_:)),
			resetAction: #selector(resetDirectionMode(_:))
		)
		directionModePopUp = directionRow.popUp
		stackView.addArrangedSubview(directionRow.row)
	}

	// MARK: - UI Setup: Phase Control

	private func setupPhaseControlSection(in stackView: NSStackView) {
		addSectionHeader(to: stackView, title: String(localized: "Phase Control"))

		// rawT カットオフ: ステッパー + テキストフィールド（開始/終了ペアを横並び）
		// End 系は UI 上「1.0 からの減算量」として表示する（内部値 = 1.0 - UI値）
		let minimizeRow = makeStepperPairRow(
			rowLabel: String(localized: "Forward rawT"),
			startDef: (key: "minimizeRawTStart", label: String(localized: "Early"), initial: Double(genieEffect.minimizeRawTStart)),
			endDef:   (key: "minimizeRawTEnd",   label: String(localized: "Late"),  initial: Double(1.0 - genieEffect.minimizeRawTEnd)),
			min: 0.0, max: 1.0, step: 0.001, format: "%.3f"
		)
		stackView.addArrangedSubview(minimizeRow)

		let restoreRow = makeStepperPairRow(
			rowLabel: String(localized: "Reverse rawT"),
			startDef: (key: "restoreRawTStart", label: String(localized: "Early"), initial: Double(genieEffect.restoreRawTStart)),
			endDef:   (key: "restoreRawTEnd",   label: String(localized: "Late"),  initial: Double(1.0 - genieEffect.restoreRawTEnd)),
			min: 0.0, max: 1.0, step: 0.001, format: "%.3f"
		)
		stackView.addArrangedSubview(restoreRow)

		addDescription(to: stackView, text: String(localized: "Raw time cutoff for animation. 'Early' skips the beginning, 'Late' trims from the end (as subtraction from 1.0)."))

		// 退避移動時のカットオフ無効化トグル（順再生:開始 / 逆再生:終了）
		skipCutoffCheckbox = NSButton(checkboxWithTitle: String(localized: "Skip Cutoff on Retreat"), target: self, action: #selector(skipCutoffOnRetreatToggled(_:)))
		skipCutoffCheckbox.controlSize = .small
		skipCutoffCheckbox.state = genieEffect.skipCutoffOnRetreat ? .on : .off
		skipCutoffCheckbox.translatesAutoresizingMaskIntoConstraints = false
		makeCheckboxRow(checkbox: skipCutoffCheckbox, in: stackView)

		addDescription(to: stackView, text: String(localized: "When enabled, cutoff that overlaps with retreat movement is ignored (forward: early cutoff, reverse: late cutoff)."))
	}

	// MARK: - UI Setup: Parameter Sliders

	private func setupParameterSliders(in stackView: NSStackView) {
		let params: [ParamDef] = [
			ParamDef(key: "slideStart",   label: String(localized: "Slide Start"),   min: 0.0,  max: 0.5, initial: Double(genieEffect.slideStart),   format: "%.2f",
				 description: String(localized: "Progress point where the sliding motion begins. Overlaps with the shrink phase for smooth transition.")),
			ParamDef(key: "stretchPower", label: String(localized: "Stretch"),       min: 0.0,  max: 5.0, initial: Double(genieEffect.stretchPower), format: "%.1f",
				 description: String(localized: "Strength of the stretching effect. Higher values make trailing edges lag more behind leading edges.")),
		]
		addSliderParams(params, to: stackView)
	}

	// MARK: - UI Setup: Easing

	private func setupEasingSection(in stackView: NSStackView) {
		let easingRow = makePopUpRow(
			label: String(localized: "Easing"),
			items: EasingType.allCases.map { $0.displayName },
			selectedIndex: genieEffect.easingType.menuIndex,
			defaultIndex: EasingType.easeInOutQuart.menuIndex,
			action: #selector(easingTypeChanged(_:)),
			resetAction: #selector(resetEasingType(_:)),
			separatorPositions: EasingType.menuSeparatorPositions
		)
		easingPopUp = easingRow.popUp
		stackView.addArrangedSubview(easingRow.row)
	}

	// MARK: - UI Setup: Curve Shape

	private func setupCurveShapeSection(in stackView: NSStackView) {
		addSectionHeader(to: stackView, title: String(localized: "Curve Shape"))

		let curveParams: [ParamDef] = [
			ParamDef(key: "curveP1Ratio", label: "P1", min: 0.1, max: 0.9, initial: Double(genieEffect.curveP1Ratio), format: "%.2f",
				 description: String(localized: "Position of Bézier control point P1 along the path. Affects the departure angle from the source window.")),
			ParamDef(key: "curveP2Ratio", label: "P2", min: 0.1, max: 0.9, initial: Double(genieEffect.curveP2Ratio), format: "%.2f",
				 description: String(localized: "Position of Bézier control point P2 along the path. Affects the arrival angle at the target.")),
		]
		addSliderParams(curveParams, to: stackView)
	}

	// MARK: - UI Setup: Retreat

	private func setupRetreatSection(in stackView: NSStackView) {
		addSectionHeader(to: stackView, title: String(localized: "Retreat"))

		let retreatParams: [ParamDef] = [
			ParamDef(key: "retreatEnd", label: String(localized: "Retreat End"), min: 0.1, max: 0.8, initial: Double(genieEffect.retreatEnd), format: "%.2f",
				 description: String(localized: "Progress point where the retreat movement completes. Controls when the window finishes moving to the corrected position.")),
		]
		addSliderParams(retreatParams, to: stackView)

		let retreatEasingRow = makePopUpRow(
			label: String(localized: "Retreat Easing"),
			items: EasingType.allCases.map { $0.displayName },
			selectedIndex: genieEffect.retreatEasingType.menuIndex,
			defaultIndex: EasingType.easeInQuad.menuIndex,
			action: #selector(retreatEasingTypeChanged(_:)),
			resetAction: #selector(resetRetreatEasingType(_:)),
			separatorPositions: EasingType.menuSeparatorPositions
		)
		retreatEasingPopUp = retreatEasingRow.popUp
		stackView.addArrangedSubview(retreatEasingRow.row)
		addDescription(to: stackView, text: String(localized: "Easing curve for the retreat movement when source and target are close together."))
	}

	// MARK: - UI Setup: Mesh Resolution

	private func setupMeshResolutionSection(in stackView: NSStackView) {
		addSectionHeader(to: stackView, title: String(localized: "Mesh Resolution"))

		let meshRow = makeStepperPairRow(
			rowLabel: String(localized: "Mesh Grid"),
			startDef: (key: "gridWidth", label: String(localized: "Width"), initial: Double(genieEffect.gridWidth)),
			endDef:   (key: "gridHeight", label: String(localized: "Height"), initial: Double(genieEffect.gridHeight)),
			min: 2, max: 64, step: 1, format: "%d"
		)
		stackView.addArrangedSubview(meshRow)
		addDescription(to: stackView, text: String(localized: "Number of divisions in the warp mesh. Higher values produce smoother deformation but use more resources."))

		let adaptiveCheckbox = NSButton(checkboxWithTitle: String(localized: "Adaptive Mesh"), target: self, action: #selector(adaptiveMeshToggled(_:)))
		adaptiveCheckbox.controlSize = .small
		adaptiveCheckbox.state = genieEffect.adaptiveMesh ? .on : .off
		adaptiveCheckbox.identifier = NSUserInterfaceItemIdentifier("adaptiveMesh")
		adaptiveCheckbox.translatesAutoresizingMaskIntoConstraints = false
		makeCheckboxRow(checkbox: adaptiveCheckbox, in: stackView)

		addDescription(to: stackView, text: String(localized: "Automatically adjust mesh resolution based on the genie direction. Uses higher resolution along the animation axis."))

		// アダプティブメッシュが有効なら初期状態でステッパーを無効化
		if genieEffect.adaptiveMesh {
			updateMeshSteppersEnabled(false)
		}
	}

	/// ParamDef 配列からスライダー行を一括追加するヘルパー
	private func addSliderParams(_ params: [ParamDef], to stackView: NSStackView) {
		for param in params {
			let row = makeSliderRow(
				label: param.label,
				value: param.initial, min: param.min, max: param.max,
				format: param.format,
				action: #selector(paramChanged(_:)),
				identifier: param.key,
				defaultValue: param.initial
			)
			paramLabels[param.key] = row.valueLabel
			stackView.addArrangedSubview(row.row)
			if let desc = param.description {
				addDescription(to: stackView, text: desc)
			}
		}
	}

	/// スライダー行を生成するヘルパー
	private func makeSliderRow(
		label: String,
		value: Double, min: Double, max: Double,
		format: String,
		action: Selector,
		identifier: String? = nil,
		defaultValue: Double? = nil
	) -> (row: NSStackView, slider: NSSlider, valueLabel: NSTextField) {
		let row = NSStackView()
		row.orientation = .horizontal
		row.spacing = 6

		let nameLabel = NSTextField(labelWithString: label + ": ")
		nameLabel.font = .systemFont(ofSize: 11)
		nameLabel.alignment = .right
		nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
		nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
		nameLabel.widthAnchor.constraint(equalToConstant: paramLabelWidth).isActive = true

		let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
		slider.controlSize = .small
		// 固定幅なし: ウインドウ幅に追従して伸縮
		slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

		let valueLabel = NSTextField(labelWithString: formattedValue(value, format: format))
		valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
		valueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
		valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
		valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

		// tooltip にデフォルト値を表示
		let defVal = defaultValue ?? value
		let tooltipText = "Default: " + formattedValue(defVal, format: format)
		slider.toolTip = tooltipText
		valueLabel.toolTip = tooltipText

		// リセットボタン
		let resetButton = NSButton(title: "↺", target: self, action: #selector(resetParam(_:)))
		resetButton.bezelStyle = .inline
		resetButton.controlSize = .small
		resetButton.font = .systemFont(ofSize: 12)
		resetButton.isBordered = true
		resetButton.toolTip = tooltipText
		resetButton.setContentHuggingPriority(.required, for: .horizontal)
		resetButton.setContentCompressionResistancePriority(.required, for: .horizontal)
		resetButton.widthAnchor.constraint(equalToConstant: 24).isActive = true

		if let id = identifier {
			slider.identifier = NSUserInterfaceItemIdentifier(id)
			resetButton.identifier = NSUserInterfaceItemIdentifier(id)
			paramDefaults[id] = (value: defVal, format: format)
			paramSliders[id] = slider
		}

		row.addArrangedSubview(nameLabel)
		row.addArrangedSubview(slider)
		row.addArrangedSubview(valueLabel)
		row.addArrangedSubview(resetButton)

		return (row, slider, valueLabel)
	}

	/// ステッパーユニット（ラベル + テキストフィールド + ステッパー + リセットボタン）を生成
	private func makeStepperUnit(
		label: String,
		value: Double, min: Double, max: Double,
		step: Double,
		format: String,
		identifier: String,
		defaultValue: Double? = nil
	) -> NSStackView {
		let unit = NSStackView()
		unit.orientation = .horizontal
		unit.spacing = 4

		let nameLabel = NSTextField(labelWithString: label + ": ")
		nameLabel.font = .systemFont(ofSize: 11)
		nameLabel.alignment = .right
		nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
		nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

		let isIntFormat = format.contains("%d")
		let textField = NSTextField(string: formattedValue(value, format: format))
		textField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
		textField.alignment = .right
		textField.controlSize = .small
		textField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
		textField.setContentCompressionResistancePriority(.required, for: .horizontal)
		textField.widthAnchor.constraint(equalToConstant: 52).isActive = true
		textField.identifier = NSUserInterfaceItemIdentifier(identifier)
		textField.target = self
		textField.action = #selector(stepperTextFieldChanged(_:))

		if isIntFormat {
			let formatter = NumberFormatter()
			formatter.numberStyle = .none
			formatter.allowsFloats = false
			formatter.minimum = NSNumber(value: min)
			formatter.maximum = NSNumber(value: max)
			textField.formatter = formatter
		}

		let stepper = NSStepper()
		stepper.minValue = min
		stepper.maxValue = max
		stepper.increment = step
		stepper.doubleValue = value
		stepper.valueWraps = false
		stepper.controlSize = .small
		stepper.autorepeat = true
		stepper.isContinuous = true
		stepper.cell?.sendAction(on: [.leftMouseDown, .leftMouseDragged, .periodic])
		stepper.identifier = NSUserInterfaceItemIdentifier(identifier)
		stepper.target = self
		stepper.action = #selector(stepperChanged(_:))

		// tooltip にデフォルト値を表示
		let defVal = defaultValue ?? value
		let tooltipText = "Default: " + formattedValue(defVal, format: format)
		stepper.toolTip = tooltipText
		textField.toolTip = tooltipText

		// リセットボタン
		let resetButton = NSButton(title: "↺", target: self, action: #selector(resetStepperParam(_:)))
		resetButton.bezelStyle = .inline
		resetButton.controlSize = .small
		resetButton.font = .systemFont(ofSize: 12)
		resetButton.isBordered = true
		resetButton.toolTip = tooltipText
		resetButton.setContentHuggingPriority(.required, for: .horizontal)
		resetButton.setContentCompressionResistancePriority(.required, for: .horizontal)
		resetButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
		resetButton.identifier = NSUserInterfaceItemIdentifier(identifier)

		paramSteppers[identifier] = stepper
		paramTextFields[identifier] = textField
		paramDefaults[identifier] = (value: defVal, format: format)

		unit.addArrangedSubview(nameLabel)
		unit.addArrangedSubview(textField)
		unit.addArrangedSubview(stepper)
		unit.addArrangedSubview(resetButton)

		return unit
	}

	/// 開始/終了ペアのステッパーを横並びで1行にまとめる
	private func makeStepperPairRow(
		rowLabel: String,
		startDef: (key: String, label: String, initial: Double),
		endDef: (key: String, label: String, initial: Double),
		min: Double, max: Double, step: Double, format: String
	) -> NSStackView {
		let row = NSStackView()
		row.orientation = .horizontal
		row.spacing = 6
		row.distribution = .equalSpacing

		let nameLabel = NSTextField(labelWithString: rowLabel + ": ")
		nameLabel.font = .systemFont(ofSize: 11)
		nameLabel.alignment = .right
		nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
		nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
		nameLabel.widthAnchor.constraint(equalToConstant: paramLabelWidth).isActive = true

		let startUnit = makeStepperUnit(
			label: startDef.label, value: startDef.initial,
			min: min, max: max, step: step, format: format,
			identifier: startDef.key, defaultValue: startDef.initial
		)

		let endUnit = makeStepperUnit(
			label: endDef.label, value: endDef.initial,
			min: min, max: max, step: step, format: format,
			identifier: endDef.key, defaultValue: endDef.initial
		)

		row.addArrangedSubview(nameLabel)
		row.addArrangedSubview(startUnit)
		row.addArrangedSubview(endUnit)
		row.addArrangedSubview(NSView())
		row.setCustomSpacing(20, after: startUnit)

		return row
	}

	/// セクションヘッダーを追加
	private func addSectionHeader(to stackView: NSStackView, title: String) {
		let label = NSTextField(labelWithString: title)
		label.font = .systemFont(ofSize: 11, weight: .semibold)
		label.textColor = .secondaryLabelColor
		stackView.addArrangedSubview(label)
	}

	/// 説明テキストを追加（スライダーのleadingに揃えたインデント）
	private func addDescription(to stackView: NSStackView, text: String) {
		let descLabel = NSTextField(labelWithString: text)
		descLabel.font = .systemFont(ofSize: 9)
		descLabel.textColor = .secondaryLabelColor
		descLabel.isSelectable = false
		descLabel.lineBreakMode = .byWordWrapping
		descLabel.maximumNumberOfLines = 0
		descLabel.translatesAutoresizingMaskIntoConstraints = false
		descLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
		descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		// wrapper NSView で Auto Layout を使い、descLabel を nameLabel幅 + spacing(6) の位置に配置
		let wrapper = NSView()
		wrapper.translatesAutoresizingMaskIntoConstraints = false
		wrapper.addSubview(descLabel)

		let descLeading = paramLabelWidth + 6
		NSLayoutConstraint.activate([
			descLabel.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: descLeading),
			descLabel.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
			descLabel.topAnchor.constraint(equalTo: wrapper.topAnchor),
			descLabel.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
		])

		stackView.addArrangedSubview(wrapper)

		// wrapper の幅を stackView の幅（edgeInsets を考慮）に一致させる
		NSLayoutConstraint.activate([
			wrapper.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: stackView.edgeInsets.left),
			wrapper.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -stackView.edgeInsets.right),
		])

	}

	/// ポップアップボタン行を生成する（スライダー行と同じレイアウト: ラベル80pt + ポップアップ + リセットボタン）
	/// separatorPositions: アイテム追加前の論理インデックス位置。その位置の直前にセパレータを挿入する。
	private func makePopUpRow(label: String,
							  items: [String],
							  selectedIndex: Int,
							  defaultIndex: Int,
							  action: Selector,
							  resetAction: Selector,
							  separatorPositions: [Int] = []) -> (row: NSStackView, popUp: NSPopUpButton)
	{
		let row = NSStackView()
		row.orientation = .horizontal
		row.spacing = 6
		row.alignment = .centerY

		let nameLabel = NSTextField(labelWithString: label + ": ")
		nameLabel.font = .systemFont(ofSize: 11)
		nameLabel.alignment = .right
		nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
		nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
		nameLabel.widthAnchor.constraint(equalToConstant: paramLabelWidth).isActive = true

		let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
		popUp.controlSize = .small
		popUp.font = .systemFont(ofSize: 11)
		popUp.removeAllItems()
		popUp.addItems(withTitles: items)

		// セパレータを挿入（後ろから挿入してインデックスのずれを回避）
		for pos in separatorPositions.sorted().reversed() {
			if pos <= popUp.menu!.items.count {
				popUp.menu!.insertItem(NSMenuItem.separator(), at: pos)
			}
		}

		popUp.selectItem(at: selectedIndex)
		popUp.target = self
		popUp.action = action
		popUp.setContentHuggingPriority(.defaultLow, for: .horizontal)

		let defaultName: String
		if defaultIndex < popUp.numberOfItems,
		   let item = popUp.item(at: defaultIndex) {
			defaultName = item.title
		} else {
			defaultName = ""
		}
		let tooltipText = "Default: \(defaultName)"
		popUp.toolTip = tooltipText

		// デフォルト項目に subtitle を設定
		if defaultIndex < popUp.numberOfItems,
		   let defaultItem = popUp.item(at: defaultIndex) {
			defaultItem.subtitle = "default"
		}

		// リセットボタン
		let resetButton = NSButton(title: "↺", target: self, action: resetAction)
		resetButton.bezelStyle = .inline
		resetButton.controlSize = .small
		resetButton.font = .systemFont(ofSize: 12)
		resetButton.isBordered = true
		resetButton.toolTip = tooltipText
		resetButton.setContentHuggingPriority(.required, for: .horizontal)
		resetButton.setContentCompressionResistancePriority(.required, for: .horizontal)
		resetButton.widthAnchor.constraint(equalToConstant: 24).isActive = true

		row.addArrangedSubview(nameLabel)
		row.addArrangedSubview(popUp)
		row.addArrangedSubview(resetButton)

		return (row, popUp)
	}

	/// スペーサーを追加
	private func addSpacer(to stackView: NSStackView, height: CGFloat) {
		let spacer = NSView()
		spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
		stackView.addArrangedSubview(spacer)
	}

	/// チェックボックスをラベル幅に揃えた wrapper ビューに配置する
	private func makeCheckboxRow(checkbox: NSButton, in stackView: NSStackView) {
		let wrapper = NSView()
		wrapper.translatesAutoresizingMaskIntoConstraints = false
		wrapper.addSubview(checkbox)

		let leading = paramLabelWidth + 6
		NSLayoutConstraint.activate([
			checkbox.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: leading),
			checkbox.topAnchor.constraint(equalTo: wrapper.topAnchor),
			checkbox.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
		])

		stackView.addArrangedSubview(wrapper)

		NSLayoutConstraint.activate([
			wrapper.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: stackView.edgeInsets.left),
			wrapper.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -stackView.edgeInsets.right),
		])
	}

	/// format 文字列に応じて値を文字列化する
	private func formattedValue(_ value: Double, format: String) -> String {
		if format.contains("%d") {
			return String(format: format, Int(value))
		}
		return String(format: format, value)
	}

	// MARK: - Actions

	/// 個別リセットボタンのアクション
	@objc private func resetParam(_ sender: NSButton) {
		guard let key = sender.identifier?.rawValue,
			  let defaults = paramDefaults[key],
			  let slider = paramSliders[key] else { return }

		slider.doubleValue = defaults.value
		paramLabels[key]?.stringValue = formattedValue(defaults.value, format: defaults.format)
		updateValueLabelWeight(key: key, currentValue: defaults.value)

		// GenieEffect のプロパティを復元
		applyParamValue(key: key, value: CGFloat(defaults.value))
	}

	/// 全リセットボタンのアクション
	@objc private func resetAllParams(_ sender: NSButton) {
		for (key, defaults) in paramDefaults {
			let formatted = formattedValue(defaults.value, format: defaults.format)
			if let slider = paramSliders[key] {
				// スライダー系パラメータ
				slider.doubleValue = defaults.value
				paramLabels[key]?.stringValue = formatted
				updateValueLabelWeight(key: key, currentValue: defaults.value)
				applyParamValue(key: key, value: CGFloat(defaults.value))
			} else if paramSteppers[key] != nil {
				// ステッパー系パラメータ
				paramSteppers[key]?.doubleValue = defaults.value
				paramTextFields[key]?.stringValue = formatted
				let internalValue = rawTInternalValue(key: key, uiValue: defaults.value)
				applyParamValue(key: key, value: internalValue)
				updateStepperLabelWeight(key: key, currentUIValue: defaults.value)
			}
		}

		// イージングをデフォルトに戻す
		genieEffect.easingType = .easeInOutQuart
		easingPopUp.selectItem(at: EasingType.easeInOutQuart.menuIndex)
		UserDefaults.standard.set(EasingType.easeInOutQuart.rawValue, forKey: Self.keyEasingType)

		// 退避イージングをデフォルトに戻す
		genieEffect.retreatEasingType = .easeInQuad
		retreatEasingPopUp.selectItem(at: EasingType.easeInQuad.menuIndex)
		UserDefaults.standard.set(EasingType.easeInQuad.rawValue, forKey: Self.keyRetreatEasingType)

		// 吸い込み方向をデフォルトに戻す
		directionMode = .auto
		directionModePopUp.selectItem(at: 0)
		UserDefaults.standard.set(GenieDirection.auto.persistenceValue, forKey: Self.keyDirectionMode)

		// rawTカットオフのUserDefaultsをクリア
		for (_, defaultsKey) in Self.rawTDefaultsKeys {
			UserDefaults.standard.removeObject(forKey: defaultsKey)
		}

		// 退避時の開始カットオフ無効化トグルをデフォルトに戻す
		genieEffect.skipCutoffOnRetreat = true
		skipCutoffCheckbox.state = .on
		UserDefaults.standard.removeObject(forKey: Self.keySkipCutoffOnRetreat)
	}

	/// キーに対応する GenieEffect プロパティに値を適用
	private func applyParamValue(key: String, value: CGFloat) {
		switch key {
		case "duration":
			durationSlider.doubleValue = Double(value)
			durationLabel.stringValue = String(format: "%.2fs", Double(value))
			UserDefaults.standard.set(Double(value), forKey: Self.keyDuration)
		case "minimizeRawTStart": genieEffect.minimizeRawTStart = value
		case "minimizeRawTEnd":   genieEffect.minimizeRawTEnd = value
		case "restoreRawTStart":  genieEffect.restoreRawTStart = value
		case "restoreRawTEnd":    genieEffect.restoreRawTEnd = value
		case "widthEnd":     genieEffect.widthEnd = value
		case "slideStart":   genieEffect.slideStart = value
		case "stretchPower": genieEffect.stretchPower = value
		case "retreatEnd":   genieEffect.retreatEnd = value
		case "curveP1Ratio":
			genieEffect.curveP1Ratio = value
			refreshDebugOverlay()
		case "curveP2Ratio":
			genieEffect.curveP2Ratio = value
			refreshDebugOverlay()
		case "gridWidth":
			genieEffect.gridWidth = Int(value.rounded())
		case "gridHeight":
			genieEffect.gridHeight = Int(value.rounded())
		default: break
		}
	}

	@objc private func durationChanged(_ sender: NSSlider) {
		durationLabel.stringValue = String(format: "%.2fs", sender.doubleValue)
		UserDefaults.standard.set(sender.doubleValue, forKey: Self.keyDuration)
		updateValueLabelWeight(key: "duration", currentValue: sender.doubleValue)
	}

	@objc private func paramChanged(_ sender: NSSlider) {
		guard let key = sender.identifier?.rawValue else { return }
		let value = CGFloat(sender.doubleValue)

		applyParamValue(key: key, value: value)

		// 値ラベルを更新
		let format = paramDefaults[key]?.format ?? "%.2f"
		paramLabels[key]?.stringValue = formattedValue(sender.doubleValue, format: format)
		updateValueLabelWeight(key: key, currentValue: sender.doubleValue)
	}

	/// rawT カットオフ用キーかどうか
	private static let rawTEndKeys: Set<String> = ["minimizeRawTEnd", "restoreRawTEnd"]

	/// UI値（End系は減算量）から内部値への変換
	private func rawTInternalValue(key: String, uiValue: Double) -> CGFloat {
		if Self.rawTEndKeys.contains(key) {
			return CGFloat(1.0 - uiValue)
		}
		return CGFloat(uiValue)
	}

	/// 内部値からUI値への変換
	private func rawTUIValue(key: String, internalValue: Double) -> Double {
		if Self.rawTEndKeys.contains(key) {
			return 1.0 - internalValue
		}
		return internalValue
	}

	/// rawT パラメータキーから UserDefaults キーへのマッピング
	private static let rawTDefaultsKeys: [String: String] = [
		"minimizeRawTStart": keyMinimizeRawTStart,
		"minimizeRawTEnd": keyMinimizeRawTEnd,
		"restoreRawTStart": keyRestoreRawTStart,
		"restoreRawTEnd": keyRestoreRawTEnd,
	]

	/// rawT パラメータの内部値を UserDefaults に保存
	private func saveRawTParam(key: String, internalValue: CGFloat) {
		guard let defaultsKey = Self.rawTDefaultsKeys[key] else { return }
		UserDefaults.standard.set(Double(internalValue), forKey: defaultsKey)
	}

	@objc private func stepperChanged(_ sender: NSStepper) {
		guard let key = sender.identifier?.rawValue else { return }
		let uiValue = sender.doubleValue
		let internalValue = rawTInternalValue(key: key, uiValue: uiValue)

		applyParamValue(key: key, value: internalValue)
		saveRawTParam(key: key, internalValue: internalValue)

		// テキストフィールドを同期
		let format = paramDefaults[key]?.format ?? "%.3f"
		paramTextFields[key]?.stringValue = formattedValue(uiValue, format: format)
		updateStepperLabelWeight(key: key, currentUIValue: uiValue)
	}

	@objc private func stepperTextFieldChanged(_ sender: NSTextField) {
		guard let key = sender.identifier?.rawValue,
			  let stepper = paramSteppers[key] else { return }
		let format = paramDefaults[key]?.format ?? "%.3f"
		let uiValue = max(stepper.minValue, min(stepper.maxValue, sender.doubleValue))
		let internalValue = rawTInternalValue(key: key, uiValue: uiValue)

		applyParamValue(key: key, value: internalValue)
		saveRawTParam(key: key, internalValue: internalValue)

		// ステッパーとテキストフィールドを同期
		stepper.doubleValue = uiValue
		sender.stringValue = formattedValue(uiValue, format: format)
		updateStepperLabelWeight(key: key, currentUIValue: uiValue)
	}

	@objc private func resetStepperParam(_ sender: NSButton) {
		guard let key = sender.identifier?.rawValue,
			  let defaults = paramDefaults[key] else { return }

		paramSteppers[key]?.doubleValue = defaults.value
		paramTextFields[key]?.stringValue = formattedValue(defaults.value, format: defaults.format)
		let internalValue = rawTInternalValue(key: key, uiValue: defaults.value)
		applyParamValue(key: key, value: internalValue)
		saveRawTParam(key: key, internalValue: internalValue)
		updateStepperLabelWeight(key: key, currentUIValue: defaults.value)
	}

	/// ステッパー用テキストフィールドのフォントウェイトを更新
	private func updateStepperLabelWeight(key: String, currentUIValue: Double) {
		guard let textField = paramTextFields[key],
			  let defaults = paramDefaults[key] else { return }
		let isDefault = abs(currentUIValue - defaults.value) < 0.0001
		let weight: NSFont.Weight = isDefault ? .regular : .bold
		textField.font = .monospacedDigitSystemFont(ofSize: 11, weight: weight)
	}

	@objc private func easingTypeChanged(_ sender: NSPopUpButton) {
		guard let easingType = EasingType.fromMenuIndex(sender.indexOfSelectedItem) else { return }
		genieEffect.easingType = easingType
		UserDefaults.standard.set(easingType.rawValue, forKey: Self.keyEasingType)
	}

	@objc private func resetEasingType(_ sender: NSButton) {
		genieEffect.easingType = .easeInOutQuart
		easingPopUp.selectItem(at: EasingType.easeInOutQuart.menuIndex)
		UserDefaults.standard.set(EasingType.easeInOutQuart.rawValue, forKey: Self.keyEasingType)
	}

	@objc private func retreatEasingTypeChanged(_ sender: NSPopUpButton) {
		guard let easingType = EasingType.fromMenuIndex(sender.indexOfSelectedItem) else { return }
		genieEffect.retreatEasingType = easingType
		UserDefaults.standard.set(easingType.rawValue, forKey: Self.keyRetreatEasingType)
	}

	@objc private func resetRetreatEasingType(_ sender: NSButton) {
		genieEffect.retreatEasingType = .easeInQuad
		retreatEasingPopUp.selectItem(at: EasingType.easeInQuad.menuIndex)
		UserDefaults.standard.set(EasingType.easeInQuad.rawValue, forKey: Self.keyRetreatEasingType)
	}

	@objc private func directionModeChanged(_ sender: NSPopUpButton) {
		let index = sender.indexOfSelectedItem
		guard let direction = GenieDirection.fromMenuIndex(index) else { return }
		directionMode = direction
		UserDefaults.standard.set(directionMode.persistenceValue, forKey: Self.keyDirectionMode)
		refreshDebugOverlay()
	}

	@objc private func resetDirectionMode(_ sender: NSButton) {
		directionMode = .auto
		directionModePopUp.selectItem(at: 0)
		UserDefaults.standard.set(GenieDirection.auto.persistenceValue, forKey: Self.keyDirectionMode)
		refreshDebugOverlay()
	}

	@objc private func skipCutoffOnRetreatToggled(_ sender: NSButton) {
		let enabled = (sender.state == .on)
		genieEffect.skipCutoffOnRetreat = enabled
		UserDefaults.standard.set(enabled, forKey: Self.keySkipCutoffOnRetreat)
	}

	@objc private func adaptiveMeshToggled(_ sender: NSButton) {
		let enabled = (sender.state == .on)
		genieEffect.adaptiveMesh = enabled
		updateMeshSteppersEnabled(!enabled)
	}

	/// メッシュ解像度ステッパーの有効/無効を切り替える
	private func updateMeshSteppersEnabled(_ enabled: Bool) {
		for key in ["gridWidth", "gridHeight"] {
			paramSteppers[key]?.isEnabled = enabled
			paramTextFields[key]?.isEnabled = enabled
		}
	}

	/// 値ラベルのフォントウェイトを更新する
	/// デフォルト値と異なる場合は bold、同じなら regular にする
	private func updateValueLabelWeight(key: String, currentValue: Double) {
		guard let label = paramLabels[key],
			  let defaults = paramDefaults[key] else { return }
		let isDefault = abs(currentValue - defaults.value) < 0.001
		let weight: NSFont.Weight = isDefault ? .regular : .bold
		label.font = .monospacedDigitSystemFont(ofSize: 11, weight: weight)
	}

	@objc private func showWireframeOverlay(_ sender: NSButton) {
		UserDefaults.standard.set(sender.state == .on, forKey: Self.keyDebugOverlay)
		if sender.state == .on {
			let overlay = DebugOverlayWindow()
			debugOverlayWindow = overlay
			genieEffect.debugOverlayReceiver = overlay

			overlay.orderFront(nil)

			// ウインドウに枠線を追加
			setDebugBorder(on: view.window, enabled: true)
			setDebugBorder(on: targetPanelController.panel, enabled: true)

			// 初期カーブを描画
			refreshDebugOverlay()

			// ドラッグ中リアルタイム更新用 DisplayLink を開始
			// （初回コールバックで lastFrame=.zero との差分を検出し描画を補完する）
			startDisplayLinkTracking()
		} else {
			// DisplayLink を停止（オーバーレイ非表示時は不要）
			stopDisplayLinkTracking()

			// 枠線を除去
			setDebugBorder(on: view.window, enabled: false)
			setDebugBorder(on: targetPanelController.panel, enabled: false)

			debugOverlayWindow?.clearCurves()
			debugOverlayWindow?.orderOut(nil)
			debugOverlayWindow = nil
			genieEffect.debugOverlayReceiver = nil
		}
	}

	/// デバッグ用枠線 (1pt, 50%アルファ赤色) の設定・解除
	private func setDebugBorder(on window: NSWindow?, enabled: Bool) {
		guard let contentView = window?.contentView else { return }
		contentView.wantsLayer = true
		if enabled {
			contentView.layer?.borderWidth = 1.0
			contentView.layer?.borderColor = NSColor.red.withAlphaComponent(0.5).cgColor
		} else {
			contentView.layer?.borderWidth = 0.0
			contentView.layer?.borderColor = nil
		}
	}

	private func saveTargetFrame() {
		let frame = targetPanelController.panel.frame
		UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.keyTargetFrame)
	}

	/// 現在のウインドウ位置からデバッグオーバーレイのカーブを更新
	private func refreshDebugOverlay() {
		guard let overlay = debugOverlayWindow,
			  let window = view.window else { return }

		// スクリーンサイズに合わせてリサイズ
		overlay.fitToScreen()

		// CGSGetWindowBounds でリアルタイム座標を取得（ドラッグ中でも最新値）
		let sourceFrame = windowFrameFromCGS(window.windowNumber) ?? window.frame
		let targetFrame = windowFrameFromCGS(targetPanelController.panel.windowNumber) ?? targetPanelController.panel.frame

		// GenieEffect にフレーム情報を一時設定してカーブを計算させる
		genieEffect.updateDebugOverlayForCurrentLayout(
			sourceFrame: sourceFrame,
			targetFrame: targetFrame,
			direction: directionMode
		)

		// 最前面に表示
		overlay.orderFront(nil)
	}

	/// ミニマイズボタン等の外部トリガーからジニーエフェクトを実行する。
	/// 最小化済みの場合は復元を実行する。
	func triggerGenie() {
		if isMinimized {
			restoreFromGenie()
		} else {
			performGenie(minimizeButton)
		}
	}

	@objc private func performGenie(_ sender: NSButton) {
		guard let window = view.window, !isMinimized else { return }

		genieEffect.duration = durationSlider.doubleValue

		// ターゲットパネルのフレームを吸い込み先として使う
		let targetFrame = targetPanelController.panel.frame

		// 吸い込みアニメーション
		minimizeButton.isEnabled = false
		minimizeDirection = directionMode

		// progress 表示コールバック
		genieEffect.progressHandler = { [weak self] progress in
			self?.targetPanelController.updateProgress(progress)
		}

		genieEffect.minimize(window: window, to: targetFrame, direction: directionMode) { [weak self] in
			guard let self = self else { return }
			self.isMinimized = true
			self.genieEffect.progressHandler = nil

			// ターゲットパネルを「保持中」状態にし、クリックで復元
			self.targetPanelController.setHolding { [weak self] in
				self?.restoreFromGenie()
			}
		}
	}

	/// ジニーエフェクトによる復元を実行する。
	private func restoreFromGenie() {
		guard let window = view.window, isMinimized else { return }

		let currentTargetFrame = targetPanelController.panel.frame

		// progress 表示コールバック（復元時）
		genieEffect.progressHandler = { [weak self] progress in
			self?.targetPanelController.updateProgress(progress)
		}

		genieEffect.restore(window: window, from: currentTargetFrame, direction: directionMode) { [weak self] in
			guard let self = self else { return }
			self.isMinimized = false
			self.minimizeButton.isEnabled = true
			self.targetPanelController.clearHolding()
			self.targetPanelController.clearProgress()
			self.genieEffect.progressHandler = nil
			window.makeKey()
		}
	}

}

// MARK: - GenieWindow

/// ミニマイズボタンでジニーエフェクトを実行するカスタムウインドウ。
///
/// Storyboard の Window Controller シーンでカスタムクラスとして指定する。
/// `miniaturize(_:)` をオーバーライドし、標準のミニマイズの代わりに
/// contentViewController 経由でジニーエフェクトを呼び出す。
class GenieWindow: NSWindow {
	override func miniaturize(_ sender: Any?) {
		if let controller = contentViewController as? ControlPanelViewController {
			controller.triggerGenie()
		} else {
			super.miniaturize(sender)
		}
	}
}



