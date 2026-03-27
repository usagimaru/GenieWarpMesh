//
//  GenieDebugOverlay.swift
//  GenieWarpMesh
//
//  デバッグオーバーレイのデータ受信プロトコル定義。
//  GenieEffect がこのプロトコルを通じてデバッグデータを配信する。
//

import Foundation

/// ソースウインドウをターゲットとの最小エッジ間隔を維持するために
/// 再配置した際に使用される、補正ベジェカーブのデータ。
///
/// ソースとターゲットの矩形が近すぎる場合、`GenieEffect` は
/// 補正フレームを計算し、二次的なカーブセットを生成する。
/// この構造体はオーバーレイ描画用にそのデータを保持する。
public struct CorrectedCurveData {
	/// 補正カーブの左辺ベジェ制御点 (CG座標系)。
	public let leftCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint)
	/// 補正カーブの右辺ベジェ制御点 (CG座標系)。
	public let rightCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint)
	/// 左カーブの P3 を超えたターゲット far edge への延長線終端。
	public let leftExtensionEnd: CGPoint
	/// 右カーブの P3 を超えたターゲット far edge への延長線終端。
	public let rightExtensionEnd: CGPoint
	/// 補正済みソースフレーム (Cocoa座標系: 左下原点)。
	public let sourceFrame: CGRect

	public init(
		leftCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint),
		rightCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint),
		leftExtensionEnd: CGPoint,
		rightExtensionEnd: CGPoint,
		sourceFrame: CGRect
	) {
		self.leftCurve = leftCurve
		self.rightCurve = rightCurve
		self.leftExtensionEnd = leftExtensionEnd
		self.rightExtensionEnd = rightExtensionEnd
		self.sourceFrame = sourceFrame
	}
}

/// ``GenieEffect`` からデバッグ可視化データを受信するプロトコル。
///
/// ジニーワープアニメーション中にベジェカーブパスやメッシュ外枠の
/// 交点データを受信するために準拠する。ワープジオメトリを可視化する
/// デバッグオーバーレイの描画に使用する。
///
/// UI 管理 (`orderFront`, `fitToScreen` 等) は準拠型の責務であり、
/// ``GenieEffect`` は関与しない。
///
/// ライブラリには組み込みの準拠型として ``DebugOverlayWindow`` が
/// 提供されている。
public protocol GenieDebugOverlay: AnyObject {
	/// カーブガイドデータが更新された際に呼ばれる。
	///
	/// - Parameters:
	///   - leftCurve: 左辺 (または上辺) カーブのベジェ制御点。
	///   - rightCurve: 右辺 (または下辺) カーブのベジェ制御点。
	///   - sourceFrame: ソースウインドウフレーム (Cocoa座標系)。
	///   - targetFrame: ターゲット矩形 (Cocoa座標系)。
	///   - fitRect: ターゲット内の scale-to-fit 矩形 (該当する場合)。
	///   - leftExtensionEnd: 左カーブの P3 を超えた延長線終端。
	///   - rightExtensionEnd: 右カーブの P3 を超えた延長線終端。
	///   - correctedData: 近接補正が有効な場合の補正カーブデータ。
	func receiveCurveGuideData(
		leftCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint),
		rightCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint),
		sourceFrame: CGRect,
		targetFrame: CGRect,
		fitRect: CGRect?,
		leftExtensionEnd: CGPoint?,
		rightExtensionEnd: CGPoint?,
		correctedData: CorrectedCurveData?
	)

	/// アニメーション中にワープメッシュの外枠交点が更新された際に呼ばれる。
	///
	/// - Parameters:
	///   - points: メッシュ外枠の交点座標の配列 (CG座標系)。
	///   - gridWidth: ワープメッシュグリッドの列数。
	///   - gridHeight: ワープメッシュグリッドの行数。
	///   - screenHeight: 座標変換に使用するスクリーン高さ。
	func receiveMeshEdgePoints(
		_ points: [CGPoint],
		gridWidth: Int,
		gridHeight: Int,
		screenHeight: CGFloat
	)

	/// 以前描画されたメッシュ外枠の可視化をクリアする際に呼ばれる。
	func clearMeshEdgePoints()
}
