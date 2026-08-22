import CoreAudio
import Foundation
@testable import JarvisCallBridge

/// Phase 3 CHECKPOINT 1 test doubles (§26: "unit tests must never mutate the actual Mac audio
/// routes"). `setDefaultOutputDevice`/`setDefaultInputDevice` update `currentSnapshot` as a side
/// effect (mirroring how a real readback would eventually reflect a real mutation), so
/// verification-step assertions in the controller exercise real logic against a believable fake,
/// not a stub.
/// §43/§44 of CHECKPOINT 2 — a single shared, ordered log that the route spy, activator spy, and
/// PCM spy all optionally append to when `orderLog` is set, letting tests assert the *relative*
/// order of route/device/PCM operations across all three collaborators (e.g. "PCM start happens
/// after both route setters", "PCM stop happens before route restoration begins").
final class CallAudioOperationOrderLog {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
}

final class CallAudioRouteControllingSpy: CallAudioRouteControlling {
    var currentSnapshot: CallAudioRouteSnapshot?
    var existingDeviceUIDs: Set<String> = []
    var failSetOutput = false
    var failSetInput = false
    var orderLog: CallAudioOperationOrderLog?

    /// Real-device fix: models CoreAudio's asynchronous default-device settling (real-device
    /// evidence showed the setter and the very next readback landing in the same millisecond,
    /// still reporting the pre-change device). While > 0, that property's readback reports
    /// `staleSnapshotOverride`'s value instead of the live, already-mutated `currentSnapshot`,
    /// decrementing once per call — independent per-property countdowns let tests model output
    /// and input converging at different rates.
    var staleOutputReadbackCount: Int = 0
    var staleInputReadbackCount: Int = 0
    var staleSnapshotOverride: CallAudioRouteSnapshot?
    /// When set, output readback is *permanently* wrong (never converges, unlike the settling
    /// delay above) — for verification-mismatch scenarios where the setter silently didn't take
    /// effect at all.
    var forceOutputUIDOnReadback: String?
    /// When set, input readback is permanently wrong — used when takeover only mutates Input.
    var forceInputUIDOnReadback: String?
    /// When set, system output readback is permanently wrong — proves a System Output mismatch
    /// fails verification even when Input/Output both match.
    var forceSystemOutputUIDOnReadback: String?

    private(set) var snapshotCallCount = 0
    private(set) var deviceExistsCalls: [String] = []
    private(set) var setOutputCalls: [String] = []
    private(set) var setInputCalls: [String] = []
    private(set) var setHogCalls: [(uid: String, pid: pid_t)] = []
    var hogPIDs: [String: pid_t] = [:]
    var failSetHog = false

    func currentRouteSnapshot() -> CallAudioRouteSnapshot? {
        snapshotCallCount += 1
        guard let real = currentSnapshot else { return nil }
        let stale = staleSnapshotOverride ?? real
        // The very first readback of a controller's lifetime is always the pre-takeover "prepare"
        // snapshot, captured before any route mutation — it becomes the verification target AND
        // the rollback/restore target, so it must always be truthful. Every simulated settling
        // delay/permanent mismatch below applies only from the second readback onward, matching
        // real CoreAudio behavior (the first read, before any change was requested, cannot itself
        // be "stale").
        let applyNoise = snapshotCallCount > 1

        let outputUID: String
        if applyNoise, staleOutputReadbackCount > 0 {
            staleOutputReadbackCount -= 1
            outputUID = stale.outputUID
        } else if applyNoise {
            outputUID = forceOutputUIDOnReadback ?? real.outputUID
        } else {
            outputUID = real.outputUID
        }

        let inputUID: String
        if applyNoise, staleInputReadbackCount > 0 {
            staleInputReadbackCount -= 1
            inputUID = stale.inputUID
        } else if applyNoise {
            inputUID = forceInputUIDOnReadback ?? real.inputUID
        } else {
            inputUID = real.inputUID
        }

        let systemOutputUID = applyNoise ? (forceSystemOutputUIDOnReadback ?? real.systemOutputUID) : real.systemOutputUID

        return CallAudioRouteSnapshot(inputUID: inputUID, outputUID: outputUID, systemOutputUID: systemOutputUID)
    }

    func deviceExists(uid: String) -> Bool {
        deviceExistsCalls.append(uid)
        return existingDeviceUIDs.contains(uid)
    }

    @discardableResult
    func setDefaultOutputDevice(uid: String) -> Bool {
        setOutputCalls.append(uid)
        orderLog?.record("route-set-output")
        guard !failSetOutput else { return false }
        if let snapshot = currentSnapshot {
            currentSnapshot = CallAudioRouteSnapshot(inputUID: snapshot.inputUID, outputUID: uid, systemOutputUID: snapshot.systemOutputUID)
        }
        return true
    }

    @discardableResult
    func setDefaultInputDevice(uid: String) -> Bool {
        setInputCalls.append(uid)
        orderLog?.record("route-set-input")
        guard !failSetInput else { return false }
        if let snapshot = currentSnapshot {
            currentSnapshot = CallAudioRouteSnapshot(inputUID: uid, outputUID: snapshot.outputUID, systemOutputUID: snapshot.systemOutputUID)
        }
        return true
    }

    func hogPID(uid: String) -> pid_t? {
        hogPIDs[uid] ?? -1
    }

    @discardableResult
    func setHogPID(uid: String, pid: pid_t) -> Bool {
        setHogCalls.append((uid, pid))
        orderLog?.record(pid == -1 ? "route-unhog" : "route-hog")
        guard !failSetHog else { return false }
        hogPIDs[uid] = pid
        return true
    }
}

final class JarvisAudioDeviceActivatingSpy: JarvisAudioDeviceActivating {
    var failCaptureActivate = false
    var failInjectActivate = false
    var orderLog: CallAudioOperationOrderLog?

    private(set) var captureActiveCalls: [Bool] = []
    private(set) var injectActiveCalls: [Bool] = []

    @discardableResult
    func setCaptureActive(_ active: Bool) -> Bool {
        captureActiveCalls.append(active)
        orderLog?.record("activator-capture-\(active)")
        return !(active && failCaptureActivate)
    }

    @discardableResult
    func setInjectActive(_ active: Bool) -> Bool {
        injectActiveCalls.append(active)
        orderLog?.record("activator-inject-\(active)")
        return !(active && failInjectActivate)
    }
}

/// Phase 3 CHECKPOINT 2 test double — never touches real CoreAudio Direct I/O. `isRunning`
/// mirrors the real controller's own idle/running distinction closely enough for coordination
/// tests (idempotent `start`/`stop`, `sendTestTone` only meaningful while "running").
final class CallAudioPCMControllingSpy: CallAudioPCMControlling {
    var failStart = false
    var orderLog: CallAudioOperationOrderLog?

    private(set) var startCalls: [String] = []
    private(set) var startRXTapDeviceIDs: [AudioDeviceID?] = []
    private(set) var stopCalls: [String] = []
    private(set) var testToneCallCount = 0
    private(set) var isRunning = false

    @discardableResult
    func start(reason: String, rxTapDeviceID: AudioDeviceID?) async -> Bool {
        startCalls.append(reason)
        startRXTapDeviceIDs.append(rxTapDeviceID)
        orderLog?.record("pcm-start")
        guard !failStart else { return false }
        isRunning = true
        return true
    }

    func stop(reason: String) async {
        stopCalls.append(reason)
        orderLog?.record("pcm-stop")
        isRunning = false
    }

    func sendTestTone() {
        testToneCallCount += 1
    }
}

@MainActor
final class RealtimeVoiceSessionControllingSpy: RealtimeVoiceSessionControlling {
    var failConnect = false
    var orderLog: CallAudioOperationOrderLog?
    private(set) var connectCalls: [String] = []
    private(set) var disconnectCalls: [String] = []

    func connect(reason: String) async {
        connectCalls.append(reason)
        orderLog?.record("realtime-connect")
        _ = failConnect
    }

    func disconnect(reason: String) async {
        disconnectCalls.append(reason)
        orderLog?.record("realtime-disconnect")
    }
}

@MainActor
enum CallAudioTestFixtures {
    static let originalInputUID = "com.example.mic"
    static let originalOutputUID = "com.example.speaker"
    static let originalSystemOutputUID = "com.example.systemspeaker"

    static func makeSpies() -> (route: CallAudioRouteControllingSpy, activator: JarvisAudioDeviceActivatingSpy, store: InMemoryCallAudioRecoveryStore, pcm: CallAudioPCMControllingSpy, mute: CallAudioProcessMuteControllingSpy) {
        let route = CallAudioRouteControllingSpy()
        route.currentSnapshot = CallAudioRouteSnapshot(inputUID: originalInputUID, outputUID: originalOutputUID, systemOutputUID: originalSystemOutputUID)
        route.existingDeviceUIDs = [JarvisAudioDeviceUIDs.capture, JarvisAudioDeviceUIDs.inject, JarvisAudioDeviceUIDs.tap, originalInputUID, originalOutputUID, originalSystemOutputUID]
        return (route, JarvisAudioDeviceActivatingSpy(), InMemoryCallAudioRecoveryStore(), CallAudioPCMControllingSpy(), CallAudioProcessMuteControllingSpy())
    }

    /// Wires the same `CallAudioOperationOrderLog` into route/activator/pcm spies so §43/§44's
    /// cross-collaborator ordering tests can assert relative sequence (e.g. "pcm-start after both
    /// route setters", "pcm-stop before route restoration begins").
    @discardableResult
    static func attachOrderLog(to spies: (route: CallAudioRouteControllingSpy, activator: JarvisAudioDeviceActivatingSpy, store: InMemoryCallAudioRecoveryStore, pcm: CallAudioPCMControllingSpy, mute: CallAudioProcessMuteControllingSpy)) -> CallAudioOperationOrderLog {
        let log = CallAudioOperationOrderLog()
        spies.route.orderLog = log
        spies.activator.orderLog = log
        spies.pcm.orderLog = log
        spies.mute.orderLog = log
        return log
    }
}

@MainActor
final class CallAudioProcessMuteControllingSpy: CallAudioProcessMuteControlling {
    var failStart = false
    var orderLog: CallAudioOperationOrderLog?

    static let stubRXTapDeviceID: AudioDeviceID = 4242

    private(set) var startCalls: [[String]] = []
    private(set) var stopCallCount = 0
    private(set) var isMuting = false
    private(set) var rxTapDeviceID: AudioDeviceID?

    @discardableResult
    func startMuting(bundleIDs: [String]) -> Bool {
        startCalls.append(bundleIDs)
        orderLog?.record("process-mute-start")
        guard !failStart else { return false }
        isMuting = true
        rxTapDeviceID = Self.stubRXTapDeviceID
        return true
    }

    func stopMuting() {
        stopCallCount += 1
        orderLog?.record("process-mute-stop")
        isMuting = false
        rxTapDeviceID = nil
    }
}
