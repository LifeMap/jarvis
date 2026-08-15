// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisCallBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JarvisCallBridge", targets: ["JarvisCallBridge"]),
        .executable(name: "JarvisAudioDriverTool", targets: ["JarvisAudioDriverTool"])
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
        ),

        // CB v2 Phase 1 — Dual Loopback Audio Driver
        .target(
            name: "JarvisLoopbackBuffer",
            path: "AudioDriver/Shared",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "JarvisAudioDriverTool",
            path: "Sources/JarvisAudioDriverTool"
        ),
        .testTarget(
            name: "JarvisAudioDriverTests",
            dependencies: ["JarvisLoopbackBuffer"],
            path: "AudioDriver/Tests"
        )
    ]
)
