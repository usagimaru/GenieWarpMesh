//
//  TargetPanelController.swift
//  GenieWarpMesh
//
//  Created by usagimaru on 2026/03/23.
//

import Cocoa

/// 吸い込み先ウインドウ。ドラッグで自由に移動でき、クリックで復元をトリガーする。
class TargetPanelController: NSObject {

	let panel: NSPanel
	private var restoreAction: (() -> Void)?
	private var isHoldingWindow = false
	private var progressLabel: NSTextField!

	override init() {
		let size = CGSize(width: 80, height: 80)
		panel = NSPanel(
			contentRect: CGRect(origin: .zero, size: size),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		super.init()

		panel.isFloatingPanel = true
		panel.becomesKeyOnlyIfNeeded = true
		panel.level = .floating
		panel.isMovableByWindowBackground = true
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true

		let contentView = NSView(frame: CGRect(origin: .zero, size: size))
		contentView.wantsLayer = true
		contentView.layer?.cornerRadius = 10
		contentView.layer?.masksToBounds = true
		contentView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

		// ラベル
		let label = NSTextField(labelWithString: String(localized: "Target"))
		label.font = .systemFont(ofSize: 11)
		label.textColor = .secondaryLabelColor
		label.alignment = .center
		label.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(label)

		// 状態ラベル（吸い込み後に「クリックで復元」と表示）
		let hintLabel = NSTextField(labelWithString: "")
		hintLabel.font = .systemFont(ofSize: 10)
		hintLabel.textColor = .tertiaryLabelColor
		hintLabel.alignment = .center
		hintLabel.tag = 100
		hintLabel.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(hintLabel)

		// progress 値表示ラベル
		let pLabel = NSTextField(labelWithString: "")
		pLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
		pLabel.textColor = .tertiaryLabelColor
		pLabel.alignment = .center
		pLabel.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(pLabel)
		progressLabel = pLabel

		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -14),
			hintLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
			hintLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
			pLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
			pLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 1),
		])

		panel.contentView = contentView
		panel.contentMinSize = CGSize(width: 60, height: 60)

		// クリック検知用のジェスチャー
		let click = NSClickGestureRecognizer(target: self, action: #selector(panelClicked(_:)))
		panel.contentView?.addGestureRecognizer(click)
	}

	/// 画面上に配置して表示する
	func show(relativeTo windowFrame: CGRect) {
		let x = windowFrame.midX - panel.frame.width / 2
		let y = windowFrame.minY - panel.frame.height - 20
		panel.setFrameOrigin(CGPoint(x: x, y: max(y, 40)))
		panel.orderFront(nil)
	}

	/// 吸い込み完了時に呼ぶ
	func setHolding(restoreAction: @escaping () -> Void) {
		isHoldingWindow = true
		self.restoreAction = restoreAction
		if let hintLabel = panel.contentView?.viewWithTag(100) as? NSTextField {
			hintLabel.stringValue = String(localized: "Click to Restore")
		}
		panel.contentView?.layer?.backgroundColor = NSColor.systemOrange.cgColor
	}

	/// 復元完了時に呼ぶ
	func clearHolding() {
		isHoldingWindow = false
		restoreAction = nil
		if let hintLabel = panel.contentView?.viewWithTag(100) as? NSTextField {
			hintLabel.stringValue = ""
		}
		panel.contentView?.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
	}

	/// progress 値を更新する
	func updateProgress(_ value: Double) {
		progressLabel.stringValue = String(format: "%.4f", value)
	}

	/// progress 表示をクリアする
	func clearProgress() {
		progressLabel.stringValue = ""
	}

	@objc private func panelClicked(_ sender: NSClickGestureRecognizer) {
		guard isHoldingWindow else { return }
		restoreAction?()
	}
}
