import Foundation

/// Placeholder for whichever later phase decides when JarvisCallAudio's Capture/Inject devices
/// should be activated (see AudioDriver/Plugin — the driver itself lives outside this SwiftPM
/// target and is controlled via CoreAudio properties, not this protocol directly). No production
/// code anywhere in CB v2 Phase 0 or Phase 1 holds a real implementation, and `BridgeStateMachine`
/// never calls it — PRD §23's "ARMED != Audio Driver Active" invariant, guarded the same way as
/// `AudioRouteMutating` (see BridgeStateMachineTests).
protocol AudioDriverActivating {
    func activateCallAudioDriver()
    func deactivateCallAudioDriver()
}
