// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClipBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClipBridge", targets: ["ClipBridge"]),
    ],
    targets: [
        .target(name: "ClipBridgeCore"),
        .executableTarget(name: "ClipBridge", dependencies: ["ClipBridgeCore"]),
        .testTarget(
            name: "ClipBridgeCoreTests",
            dependencies: ["ClipBridgeCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
