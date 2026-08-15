// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisCallBridgeFeasibility",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JarvisCallBridgeFeasibility", targets: ["JarvisCallBridgeFeasibility"])
    ],
    targets: [
        .target(
            name: "JarvisVMicRing",
            path: "HALPlugin/Shared",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "JarvisCallBridgeFeasibility",
            dependencies: ["JarvisVMicRing"],
            path: ".",
            exclude: ["README.md", "Info.plist", "build-app.sh", "HALPlugin"],
            sources: [
                "JarvisCallBridgeApp.swift",
                "FeasibilityModel.swift",
                "CallStateMonitor.swift",
                "RXAudioProbe.swift",
                "TXAudioProbe.swift",
                "VirtualMicTXProbe.swift",
                "SeparationMonitor.swift",
                "PhoneAppAccessibilityProbe.swift",
                "ProbeLogger.swift"
            ],
            resources: [
                .copy("Resources/tx-sample.wav")
            ]
        )
    ]
)
