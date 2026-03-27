//
//  GenieDirection.swift
//  GenieWarpMesh
//
//  © 2026 usagimaru.
//  ジニーワープエフェクトの吸い込み方向。
//

import Foundation

/// ジニーワープエフェクトがアニメーションする方向。
///
/// `.auto` を使用すると、ソースウインドウとターゲット矩形の相対位置から
/// ライブラリが方向を自動判定する。
/// 具体的な方向 (`.bottom`, `.top`, `.left`, `.right`) を指定することで、
/// ワープの辺を明示的に制御することもできる。
public enum GenieDirection {
	/// ソース/ターゲットのジオメトリから自動判定する。
	case auto
	/// 下辺に向かって吸い込む。
	case bottom
	/// 左辺に向かって吸い込む。
	case left
	/// 右辺に向かって吸い込む。
	case right
	/// 上辺に向かって吸い込む。
	case top

	/// `.auto` を具体的な方向に解決する。
	///
	/// ソースとターゲットの矩形の中心間の水平・垂直距離を比較し、
	/// 支配的な軸に基づいて方向を決定する。
	/// `.auto` 以外のケースでは `self` をそのまま返す。
	///
	/// 座標系: Cocoa (左下原点)。
	public func resolved(from sourceFrame: CGRect, to targetFrame: CGRect) -> GenieDirection {
		guard case .auto = self else { return self }

		let dx = targetFrame.midX - sourceFrame.midX
		let dy = targetFrame.midY - sourceFrame.midY

		if abs(dx) > abs(dy) {
			return dx < 0 ? .left : .right
		} else {
			return dy < 0 ? .bottom : .top
		}
	}
}
