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
            dependencies: ["JarvisPCMRealtime"],
            path: "Sources/JarvisCallBridge"
        ),
        .testTarget(
            name: "JarvisCallBridgeTests",
            dependencies: ["JarvisCallBridge", "JarvisPCMRealtime", "JarvisLoopbackBuffer"],
            path: "Tests/JarvisCallBridgeTests"
        ),

        // Phase 3 CHECKPOINT 2 — the native C AudioDeviceIOProc callbacks for Capture/Inject PCM,
        // plus their lock-free C11 atomic state. Swift's SystemCallAudioPCMController registers
        // these as plain C function pointers via AudioDeviceCreateIOProcID — no Swift code ever
        // executes on the CoreAudio real-time callback thread.
        .target(
            name: "JarvisPCMRealtime",
            dependencies: ["JarvisLoopbackBuffer"],
            path: "Sources/JarvisPCMRealtime",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
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
        ),
        // Phase 3 CHECKPOINT 2 — pure decode-logic tests for JarvisAudioDriverTool (e.g. the
        // Rpcm/PCMDiagnostics CFData decoder), never exercising real CoreAudio/a real device.
        .testTarget(
            name: "JarvisAudioDriverToolTests",
            dependencies: ["JarvisAudioDriverTool"],
            path: "Tests/JarvisAudioDriverToolTests"
        )
    ]
)
