//
//  GenieDirection+DisplayName.swift
//  GenieWarpMesh
//
//  © 2026 usagimaru.
//  デモアプリ用: GenieDirection の表示名を定義する extension。
//

import Foundation
import GenieWarpMesh

extension GenieDirection: @retroactive CaseIterable {
	public static var allCases: [GenieDirection] {
		[.auto, .bottom, .top, .left, .right]
	}
}

extension GenieDirection {
	/// メニュー表示用の名前
	var displayName: String {
		switch self {
			case .auto:
				return String(localized: "Auto")
			case .bottom:
				return String(localized: "Bottom")
			case .top:
				return String(localized: "Top")
			case .left:
				return String(localized: "Left")
			case .right:
				return String(localized: "Right")
		}
	}

	/// メニューインデックスから GenieDirection を取得
	static func fromMenuIndex(_ index: Int) -> GenieDirection? {
		guard index >= 0, index < allCases.count else { return nil }
		return allCases[index]
	}

	/// UserDefaults 保存用の整数値
	var persistenceValue: Int {
		switch self {
			case .auto:   return 0
			case .bottom: return 1
			case .top:    return 2
			case .left:   return 3
			case .right:  return 4
		}
	}

	/// UserDefaults から復元
	static func fromPersistenceValue(_ value: Int) -> GenieDirection? {
		switch value {
			case 0: return .auto
			case 1: return .bottom
			case 2: return .top
			case 3: return .left
			case 4: return .right
			default: return nil
		}
	}
}
