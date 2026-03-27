// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "GenieWarpMesh",
	platforms: [.macOS(.v14)],
	products: [
		.library(name: "GenieWarpMesh", targets: ["GenieWarpMesh"]),
		.library(name: "CGSPrivate", targets: ["CGSPrivate"]),
	],
	targets: [
		.target(
			name: "CGSPrivate",
			path: "Sources/CGSPrivate",
			publicHeadersPath: "include"
		),
		.target(
			name: "GenieWarpMesh",
			dependencies: ["CGSPrivate"],
			path: "Sources/GenieWarpMesh",
			linkerSettings: [.linkedFramework("CoreGraphics")]
		),
	]
)
