//
//  EasingType.swift
//  GenieWarpMesh
//
//  アニメーションタイミング用のイージングカーブ型。
//

import Foundation

/// アニメーションタイミングを制御するイージングカーブの種類。
///
/// 各ケースは多項式曲線 (2次〜5次) に基づく標準的なイージング関数に対応する。
/// 命名は一般的な慣例に従う: `easeIn` は加速、`easeOut` は減速、
/// `easeInOut` はその両方。
public enum EasingType: Int, CaseIterable, Sendable {
	/// 線形補間 (イージングなし)。
	case linear
	/// 2次 ease-in (速度ゼロから加速)。
	case easeInQuad
	/// 3次 ease-in。
	case easeInCubic
	/// 4次 ease-in。
	case easeInQuart
	/// 5次 ease-in。
	case easeInQuint
	/// 2次 ease-out (速度ゼロまで減速)。
	case easeOutQuad
	/// 3次 ease-out。
	case easeOutCubic
	/// 4次 ease-out。
	case easeOutQuart
	/// 5次 ease-out。
	case easeOutQuint
	/// 2次 ease-in-out (加速してから減速)。
	case easeInOutQuad
	/// 3次 ease-in-out。
	case easeInOutCubic
	/// 4次 ease-in-out。
	case easeInOutQuart
	/// 5次 ease-in-out。
	case easeInOutQuint

	/// 正規化された時間値に対してイージング関数を評価する。
	///
	/// - Parameter t: アニメーションの進行度を表す `0.0...1.0` の値。
	/// - Returns: イージング適用後の値。同じく `0.0...1.0` の範囲。
	public func function(_ t: Double) -> Double {
		switch self {
		case .linear:
			return t
		case .easeInQuad:
			return pow(t, 2)
		case .easeInCubic:
			return pow(t, 3)
		case .easeInQuart:
			return pow(t, 4)
		case .easeInQuint:
			return pow(t, 5)
		case .easeOutQuad:
			let u = 1.0 - t
			return 1.0 - pow(u, 2)
		case .easeOutCubic:
			let u = 1.0 - t
			return 1.0 - pow(u, 3)
		case .easeOutQuart:
			let u = 1.0 - t
			return 1.0 - pow(u, 4)
		case .easeOutQuint:
			let u = 1.0 - t
			return 1.0 - pow(u, 5)
		case .easeInOutQuad:
			if t < 0.5 {
				return 2.0 * pow(t, 2)
			} else {
				let u = -2.0 * t + 2.0
				return 1.0 - pow(u, 2) / 2.0
			}
		case .easeInOutCubic:
			if t < 0.5 {
				return 4.0 * pow(t, 3)
			} else {
				let u = -2.0 * t + 2.0
				return 1.0 - pow(u, 3) / 2.0
			}
		case .easeInOutQuart:
			if t < 0.5 {
				return 8.0 * pow(t, 4)
			} else {
				let u = -2.0 * t + 2.0
				return 1.0 - pow(u, 4) / 2.0
			}
		case .easeInOutQuint:
			if t < 0.5 {
				return 16.0 * pow(t, 5)
			} else {
				let u = -2.0 * t + 2.0
				return 1.0 - pow(u, 5) / 2.0
			}
		}
	}
}
