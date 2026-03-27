//
//  EasingType+Menu.swift
//  GenieWarpMesh
//
//  © 2026 usagimaru.
//  デモアプリ用: EasingType の表示名とメニュー関連ヘルパーを定義する extension。
//

import Foundation
import GenieWarpMesh

extension EasingType {
	/// メニュー表示用の名前
	var displayName: String {
		switch self {
		case .linear:
			return "Linear"
		case .easeInQuad:
			return "Ease In Quad"
		case .easeInCubic:
			return "Ease In Cubic"
		case .easeInQuart:
			return "Ease In Quart"
		case .easeInQuint:
			return "Ease In Quint"
		case .easeOutQuad:
			return "Ease Out Quad"
		case .easeOutCubic:
			return "Ease Out Cubic"
		case .easeOutQuart:
			return "Ease Out Quart"
		case .easeOutQuint:
			return "Ease Out Quint"
		case .easeInOutQuad:
			return "Ease In-Out Quad"
		case .easeInOutCubic:
			return "Ease In-Out Cubic"
		case .easeInOutQuart:
			return "Ease In-Out Quart"
		case .easeInOutQuint:
			return "Ease In-Out Quint"
		}
	}

	/// セパレータ挿入位置（Linear/EaseIn/EaseOut/EaseInOut の各グループ境界）
	/// アイテム追加前の論理インデックス位置を返す。
	static var menuSeparatorPositions: [Int] {
		// linear(0), easeInQuad..easeInQuint(1-4), easeOutQuad..easeOutQuint(5-8), easeInOutQuad..easeInOutQuint(9-12)
		// セパレータ: index 1 の前、index 5 の前、index 9 の前
		return [1, 5, 9]
	}

	/// セパレータを考慮した NSPopUpButton 用のメニューインデックス
	var menuIndex: Int {
		let raw = self.rawValue
		// セパレータの数を加算
		var offset = 0
		for pos in Self.menuSeparatorPositions {
			if raw >= pos {
				offset += 1
			}
		}
		return raw + offset
	}

	/// セパレータを考慮したメニューインデックスから EasingType を復元
	static func fromMenuIndex(_ index: Int) -> EasingType? {
		// セパレータ位置を考慮してオフセットを差し引く
		var separatorsBeforeIndex = 0
		// セパレータが挿入される実際のメニューインデックスを計算
		var realSepPositions: [Int] = []
		for (i, pos) in menuSeparatorPositions.enumerated() {
			realSepPositions.append(pos + i)
		}
		// セパレータ自体が選択された場合は nil
		if realSepPositions.contains(index) {
			return nil
		}
		for realPos in realSepPositions {
			if index > realPos {
				separatorsBeforeIndex += 1
			}
		}
		let rawValue = index - separatorsBeforeIndex
		return EasingType(rawValue: rawValue)
	}
}
