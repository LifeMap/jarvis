import Foundation

func printUsage() {
    print("""
    JarvisAudioDriverTool — CB v2 Phase 1 diagnostic CLI for JarvisCallAudio.driver

    Usage:
      swift run JarvisAudioDriverTool status
      swift run JarvisAudioDriverTool list
      swift run JarvisAudioDriverTool inspect   (READ-ONLY — Phase 3 route-setter investigation)
      swift run JarvisAudioDriverTool pcm-inspect   (READ-ONLY — Phase 3 CHECKPOINT 2 RX investigation)
      swift run JarvisAudioDriverTool pcm-inspect-stability [iterations]   (READ-ONLY — run WHILE IDLE, before another real-call retest)
      swift run JarvisAudioDriverTool activate [capture|inject|all]
      swift run JarvisAudioDriverTool deactivate [capture|inject|all]
      swift run JarvisAudioDriverTool clear [capture|inject|all]
      swift run JarvisAudioDriverTool test-capture [seconds]
      swift run JarvisAudioDriverTool test-inject [seconds]
      swift run JarvisAudioDriverTool test-isolation [seconds]
      swift run JarvisAudioDriverTool stress [iterations]
    """)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    printUsage()
    exit(1)
}

let command = arguments[1]
let rest = Array(arguments.dropFirst(2))

func target(from rest: [String], default def: DriverTarget = .all) -> DriverTarget {
    guard let first = rest.first, let parsed = DriverTarget(rawValue: first) else { return def }
    return parsed
}

switch command {
case "status":
    Commands.status()
case "list":
    Commands.list()
case "inspect":
    Commands.inspect()
case "pcm-inspect":
    Commands.pcmInspect()
case "pcm-inspect-stability":
    let iterations = rest.first.flatMap(Int.init) ?? 50
    Commands.pcmInspectStability(iterations: iterations)
case "activate":
    Commands.setActive(target(from: rest), true)
case "deactivate":
    Commands.setActive(target(from: rest), false)
case "clear":
    Commands.clearBuffers(target(from: rest))
case "test-capture":
    let seconds = rest.first.flatMap(Double.init) ?? 2
    Commands.loopbackTest(label: "Jarvis Call Capture", uid: JarvisCallAudio.Capture.deviceUID, seconds: seconds)
case "test-inject":
    let seconds = rest.first.flatMap(Double.init) ?? 2
    Commands.loopbackTest(label: "Jarvis Call Inject", uid: JarvisCallAudio.Inject.deviceUID, seconds: seconds)
case "test-isolation":
    let seconds = rest.first.flatMap(Double.init) ?? 2
    Commands.isolationTest(seconds: seconds)
case "stress":
    let iterations = rest.first.flatMap(Int.init) ?? 10
    Commands.stress(iterations: iterations)
default:
    printUsage()
    exit(1)
}
