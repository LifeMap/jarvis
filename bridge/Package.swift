// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisCallBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JarvisCallBridge", targets: ["JarvisCallBridge"])
    ],
    targets: [
        .executableTarget(
            name: "JarvisCallBridge",
            path: "Sources/JarvisCallBridge"
        ),
        .testTarget(
            name: "JarvisCallBridgeTests",
            dependencies: ["JarvisCallBridge"],
            path: "Tests/JarvisCallBridgeTests"
        )
    ]
)
