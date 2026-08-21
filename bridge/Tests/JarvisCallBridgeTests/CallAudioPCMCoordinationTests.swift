import XCTest
@testable import JarvisCallBridge

/// Phase 3 CHECKPOINT 2 — PCM start/stop coordination, owned by `CallAudioSessionController`
/// (§7/§23: "protocol-injected PCM controller coordinated by CallAudioSessionController").
/// `CallAudioPCMControllingSpy` never touches real CoreAudio; `CallAudioOperationOrderLog`
/// (shared across the route/activator/pcm spies) lets these tests assert the *relative* order of
/// operations across all three collaborators, proving §21/§22's start/stop ordering in code, not
/// just by inspection.
@MainActor
final class CallAudioPCMCoordinationTests: XCTestCase {
    private func makeController(_ spies: (route: CallAudioRouteControllingSpy, activator: JarvisAudioDeviceActivatingSpy, store: InMemoryCallAudioRecoveryStore, pcm: CallAudioPCMControllingSpy, mute: CallAudioProcessMuteControllingSpy)) -> CallAudioSessionController {
        CallAudioSessionController(
            routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store, pcmController: spies.pcm, processMute: spies.mute, logger: BridgeLogger(),
            convergenceMaxAttempts: 5, convergencePollNanoseconds: 1_000_000
        )
    }

    // MARK: - §42 items 1-3: PCM never starts outside a verified, routed Active call

    func testIdleNeverStartsPCM() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: true)
        XCTAssertTrue(spies.pcm.startCalls.isEmpty)
    }

    func testRingingNeverStartsPCM() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        await controller.handleLifecycleChange(callState: .ringing, session: CallSession(), workModeArmed: true)
        XCTAssertEqual(controller.state, .routed, "ringing now takes the route, but PCM must still stay closed")
        XCTAssertTrue(spies.pcm.startCalls.isEmpty)
    }

    func testRingingThenActiveStartsPCMExactlyOnceAndRepeatedTicksAreIdempotent() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .ringing, session: session, workModeArmed: true)
        XCTAssertTrue(spies.pcm.startCalls.isEmpty)
        for _ in 0..<5 {
            await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        }
        XCTAssertEqual(spies.pcm.startCalls, ["takeover"])
        XCTAssertTrue(spies.pcm.isRunning)
    }

    func testAnsweringNeverStartsPCM() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        await controller.handleLifecycleChange(callState: .answering, session: CallSession(), workModeArmed: true)
        XCTAssertTrue(spies.pcm.startCalls.isEmpty)
    }

    // §42 item 4: Active before route verification passes must not start PCM — forced via a
    // permanent readback mismatch so forward convergence times out and rollback fires instead of
    // ever reaching the PCM-start step.
    func testActiveBeforeRouteVerificationPassDoesNotStartPCM() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.route.forceOutputUIDOnReadback = "com.example.permanently-stuck-device"
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertNotEqual(controller.state, .routed)
        XCTAssertTrue(spies.pcm.startCalls.isEmpty, "PCM must never start when route verification never passed")
    }

    // MARK: - §42 items 5-7: start count / idempotency / fresh session after restore

    func testSuccessfulRoutedTransitionStartsPCMExactlyOnce() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.pcm.startCalls, ["takeover"])
    }

    func testRepeatedActiveTicksForSameSessionNeverStartDuplicatePCM() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()

        for _ in 0..<5 {
            await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        }

        XCTAssertEqual(spies.pcm.startCalls.count, 1, "repeated ticks against the already-routed session must never re-start PCM")
    }

    func testNewCallAfterCompleteRestoreStartsAFreshPCMSession() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)
        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: true)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(spies.pcm.stopCalls, ["call-ended"])

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.pcm.startCalls, ["takeover", "takeover"], "a genuinely new call must get its own fresh PCM start")
    }

    // MARK: - §43: start ordering — PCM only after both route setters have already run

    func testPCMStartHappensAfterBothRouteSettersOnSuccessfulTakeover() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let log = CallAudioTestFixtures.attachOrderLog(to: spies)
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        let outputIndex = log.entries.firstIndex(of: "route-set-output")
        let inputIndex = log.entries.firstIndex(of: "route-set-input")
        let pcmStartIndex = log.entries.firstIndex(of: "pcm-start")
        XCTAssertNotNil(outputIndex, "takeover must set Default Output to Capture before PCM starts")
        XCTAssertNotNil(inputIndex); XCTAssertNotNil(pcmStartIndex)
        XCTAssertLessThan(outputIndex!, inputIndex!, "Default Output → Capture must precede Default Input → Inject")
        XCTAssertLessThan(inputIndex!, pcmStartIndex!, "PCM must start only after both route setters")
    }

    // MARK: - §44: stop ordering — PCM fully stops before route restoration begins

    func testPCMStopHappensImmediatelyBeforeRouteRestorationOnConfirmedIdle() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let log = CallAudioTestFixtures.attachOrderLog(to: spies)
        let controller = makeController(spies)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)
        let pcmStartIndex = log.entries.firstIndex(of: "pcm-start")!

        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: false)
        XCTAssertEqual(controller.state, .idle)

        // Nothing else touches route/activator/pcm between "routed" and the restore's own stop
        // call, so the very next entry after pcm-start must be pcm-stop — and it must precede
        // both restore route setters.
        XCTAssertEqual(log.entries[pcmStartIndex + 1], "pcm-stop")
        let pcmStopIndex = pcmStartIndex + 1
        let restoreOutputIndex = log.entries[(pcmStartIndex + 1)...].firstIndex(of: "route-set-output")!
        let restoreInputIndex = log.entries[(pcmStartIndex + 1)...].firstIndex(of: "route-set-input")!
        XCTAssertLessThan(pcmStopIndex, restoreOutputIndex)
        XCTAssertLessThan(pcmStopIndex, restoreInputIndex)
    }

    func testPCMStopHappensBeforeDeviceDeactivationOnConfirmedIdle() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let log = CallAudioTestFixtures.attachOrderLog(to: spies)
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)
        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: false)

        let pcmStopIndex = log.entries.lastIndex(of: "pcm-stop")!
        let captureDeactivateIndex = log.entries.lastIndex(of: "activator-capture-false")!
        let injectDeactivateIndex = log.entries.lastIndex(of: "activator-inject-false")!
        XCTAssertLessThan(pcmStopIndex, captureDeactivateIndex, "no IOProc may remain active after device deactivation begins")
        XCTAssertLessThan(pcmStopIndex, injectDeactivateIndex)
    }

    // MARK: - §45: emergency paths

    func testWorkModeOffWhilePCMRunningStopsPCMBeforeRestoring() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let log = CallAudioTestFixtures.attachOrderLog(to: spies)
        let controller = makeController(spies)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(spies.pcm.isRunning, true)

        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: false)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(spies.pcm.stopCalls.last, "work-mode-off")
        let pcmStopIndex = log.entries.lastIndex(of: "pcm-stop")!
        let restoreOutputIndex = log.entries[pcmStopIndex...].firstIndex(of: "route-set-output")!
        XCTAssertLessThan(pcmStopIndex, restoreOutputIndex)
    }

    func testAppQuitEmergencyRestoreStopsPCMBeforeRestoring() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)
        XCTAssertEqual(spies.pcm.isRunning, true)

        await controller.emergencyRestore(reason: "app-quit")

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(spies.pcm.stopCalls.last, "app-quit")
        XCTAssertEqual(spies.pcm.isRunning, false)
    }

    func testRouteOwnershipLossWhilePCMRunningStopsPCMBeforeDeactivating() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let log = CallAudioTestFixtures.attachOrderLog(to: spies)
        let controller = makeController(spies)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(spies.pcm.isRunning, true)

        spies.route.currentSnapshot = CallAudioRouteSnapshot(inputUID: "com.example.airpods", outputUID: "com.example.airpods", systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID)
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(spies.pcm.stopCalls.last, "ownership-loss")
        let pcmStopIndex = log.entries.lastIndex(of: "pcm-stop")!
        let deactivateIndex = log.entries[pcmStopIndex...].firstIndex(of: "activator-inject-false")!
        XCTAssertLessThan(pcmStopIndex, deactivateIndex)
    }

    // §25: PCM start failure must emergency-restore the route, not leave the call routed with a
    // non-functioning PCM runtime.
    func testPCMStartFailureTriggersRouteRollbackAndExcludesSession() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.pcm.failStart = true
        let controller = makeController(spies)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)

        XCTAssertEqual(controller.state, .idle, "route must be fully rolled back when PCM fails to start")
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, CallAudioTestFixtures.originalOutputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.inputUID, CallAudioTestFixtures.originalInputUID)
        XCTAssertNil(spies.store.storedRecord, "recovery record must be cleared on a successful emergency rollback")

        let setOutputCallsAfterFailure = spies.route.setOutputCalls.count
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(spies.route.setOutputCalls.count, setOutputCallsAfterFailure, "the same session must never be retried after a PCM start failure")
    }

    // MARK: - §52: CHECKPOINT 1 regression — recovery record semantics unaffected by PCM

    func testSuccessfulTakeoverStillLeavesRecoveryRecordPresentWhileRoutedWithPCMRunning() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertTrue(controller.hasPersistedRecoveryRecord)
        XCTAssertTrue(spies.pcm.isRunning)
    }

    func testSuccessfulRestoreStillClearsRecoveryRecordWithPCMStopped() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: false)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.hasPersistedRecoveryRecord)
        XCTAssertFalse(spies.pcm.isRunning)
    }

    func testRealtimeConnectsOnlyAfterSuccessfulPCMStartOnActive() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let realtime = RealtimeVoiceSessionControllingSpy()
        let log = CallAudioTestFixtures.attachOrderLog(to: spies)
        realtime.orderLog = log
        let controller = CallAudioSessionController(
            routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store,
            pcmController: spies.pcm, realtimeSession: realtime, processMute: spies.mute,
            logger: BridgeLogger(), convergenceMaxAttempts: 5, convergencePollNanoseconds: 1_000_000
        )
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .ringing, session: session, workModeArmed: true)
        XCTAssertTrue(realtime.connectCalls.isEmpty)
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(realtime.connectCalls, ["takeover"])
        let pcmStart = log.entries.firstIndex(of: "pcm-start")!
        let rtConnect = log.entries.firstIndex(of: "realtime-connect")!
        XCTAssertLessThan(pcmStart, rtConnect)
    }

    func testRealtimeDisconnectsBeforePCMStopOnWorkModeOff() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let realtime = RealtimeVoiceSessionControllingSpy()
        let log = CallAudioTestFixtures.attachOrderLog(to: spies)
        realtime.orderLog = log
        let controller = CallAudioSessionController(
            routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store,
            pcmController: spies.pcm, realtimeSession: realtime, processMute: spies.mute,
            logger: BridgeLogger(), convergenceMaxAttempts: 5, convergencePollNanoseconds: 1_000_000
        )
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: false)
        XCTAssertEqual(realtime.disconnectCalls.last, "work-mode-off")
        let disconnect = log.entries.lastIndex(of: "realtime-disconnect")!
        let pcmStop = log.entries.lastIndex(of: "pcm-stop")!
        let restoreOutput = log.entries[pcmStop...].firstIndex(of: "route-set-output")!
        XCTAssertLessThan(disconnect, pcmStop)
        XCTAssertLessThan(pcmStop, restoreOutput)
    }

    func testRealtimeDisconnectsBeforePCMStopOnOwnershipLoss() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let realtime = RealtimeVoiceSessionControllingSpy()
        let log = CallAudioTestFixtures.attachOrderLog(to: spies)
        realtime.orderLog = log
        let controller = CallAudioSessionController(
            routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store,
            pcmController: spies.pcm, realtimeSession: realtime, processMute: spies.mute,
            logger: BridgeLogger(), convergenceMaxAttempts: 5, convergencePollNanoseconds: 1_000_000
        )
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        spies.route.currentSnapshot = CallAudioRouteSnapshot(
            inputUID: "com.example.airpods", outputUID: "com.example.airpods",
            systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID
        )
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(realtime.disconnectCalls.last, "ownership-loss")
        XCTAssertLessThan(log.entries.lastIndex(of: "realtime-disconnect")!, log.entries.lastIndex(of: "pcm-stop")!)
    }

    func testRealtimeConnectFailureDoesNotRollbackRoute() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let realtime = RealtimeVoiceSessionControllingSpy()
        realtime.failConnect = true
        let controller = CallAudioSessionController(
            routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store,
            pcmController: spies.pcm, realtimeSession: realtime, processMute: spies.mute,
            logger: BridgeLogger(), convergenceMaxAttempts: 5, convergencePollNanoseconds: 1_000_000
        )
        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)
        XCTAssertTrue(spies.pcm.isRunning)
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, JarvisAudioDeviceUIDs.capture)
    }
}
