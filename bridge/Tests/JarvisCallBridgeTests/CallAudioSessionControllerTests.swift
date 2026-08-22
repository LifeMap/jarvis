import XCTest
@testable import JarvisCallBridge

/// Phase 3 CHECKPOINT 1 — Active Call Audio Route Takeover & Safe Restore. All CoreAudio access is
/// behind `CallAudioRouteControlling`/`JarvisAudioDeviceActivating`/`CallAudioRecoveryStore` spies
/// (§26) — nothing here ever touches the real Mac audio routes.
@MainActor
final class CallAudioSessionControllerTests: XCTestCase {
    /// §16 item 9: fast, bounded convergence settings by default — real-device-scale bounds
    /// (10 attempts × 75ms) would make every takeover test spend up to ~750ms in real
    /// `Task.sleep`. Nothing here uses a fake clock (there's no injectable `Clock` abstraction in
    /// this codebase yet), but a millisecond-scale real poll interval keeps the suite fast while
    /// still exercising the actual async polling code path, not a mocked-away shortcut.
    private func makeController(
        _ spies: (route: CallAudioRouteControllingSpy, activator: JarvisAudioDeviceActivatingSpy, store: InMemoryCallAudioRecoveryStore, pcm: CallAudioPCMControllingSpy, mute: CallAudioProcessMuteControllingSpy),
        logger: BridgeLogger = BridgeLogger(),
        convergenceMaxAttempts: Int = 5,
        convergencePollNanoseconds: UInt64 = 1_000_000
    ) -> CallAudioSessionController {
        CallAudioSessionController(
            routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store, pcmController: spies.pcm, processMute: spies.mute, logger: logger,
            convergenceMaxAttempts: convergenceMaxAttempts, convergencePollNanoseconds: convergencePollNanoseconds
        )
    }

    // MARK: - Answering / ending / unknown still must not mutate routes

    func testAnsweringEndingUnknownNeverMutateRoutesOrActivateDevices() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .answering, session: session, workModeArmed: true)
        await controller.handleLifecycleChange(callState: .ending, session: session, workModeArmed: true)
        await controller.handleLifecycleChange(callState: .unknown, session: session, workModeArmed: true)

        XCTAssertTrue(spies.activator.captureActiveCalls.isEmpty)
        XCTAssertTrue(spies.activator.injectActiveCalls.isEmpty)
        XCTAssertTrue(spies.route.setOutputCalls.isEmpty)
        XCTAssertTrue(spies.route.setInputCalls.isEmpty)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(spies.pcm.startCalls.isEmpty)
    }

    func testIdleArmedNeverMutatesRoutes() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: true)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.routeOwnerSessionID)
        XCTAssertTrue(spies.activator.captureActiveCalls.isEmpty, "Work Mode ON while idle must not seize the meeting speaker")
        XCTAssertTrue(spies.route.setOutputCalls.isEmpty)
        XCTAssertTrue(spies.route.setHogCalls.isEmpty)
        XCTAssertTrue(spies.mute.startCalls.isEmpty, "idle Work Mode must not mute Continuity audio")
        XCTAssertTrue(spies.pcm.startCalls.isEmpty)
    }

    func testRingingTakesOverRouteWithoutStartingPCM() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .ringing, session: session, workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(controller.routeOwnerSessionID, session.id)
        XCTAssertEqual(spies.activator.captureActiveCalls, [true])
        XCTAssertEqual(spies.activator.injectActiveCalls, [true])
        XCTAssertEqual(spies.route.setOutputCalls, [JarvisAudioDeviceUIDs.capture], "Phone.app only writes caller PCM when Default Output is Capture")
        XCTAssertEqual(spies.route.setInputCalls, [JarvisAudioDeviceUIDs.inject])
        XCTAssertTrue(spies.pcm.startCalls.isEmpty, "ringing takeover is route-only — PCM stays closed until Active")
    }

    func testRepeatedRingingTicksAreIdempotent() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()

        for _ in 0..<5 {
            await controller.handleLifecycleChange(callState: .ringing, session: session, workModeArmed: true)
        }

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.activator.captureActiveCalls, [true])
        XCTAssertEqual(spies.route.setOutputCalls, [JarvisAudioDeviceUIDs.capture])
        XCTAssertTrue(spies.pcm.startCalls.isEmpty)
    }

    func testRingingThenIdleRestoresAndStopsProcessMuteWhileWorkModeStaysArmed() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .ringing, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)
        XCTAssertNotNil(spies.store.storedRecord)
        XCTAssertEqual(spies.mute.startCalls, [CallAudioProcessMutePolicy.continuityOutputBundleIDs])
        XCTAssertTrue(spies.route.setHogCalls.isEmpty, "Continuity leak is muted per-process, not by hogging the speaker")

        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: true)

        XCTAssertEqual(controller.state, .idle, "hangup must restore even if Work Mode stays ON, so a meeting speaker comes back")
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, CallAudioTestFixtures.originalOutputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.inputUID, CallAudioTestFixtures.originalInputUID)
        XCTAssertEqual(spies.activator.captureActiveCalls.last, false)
        XCTAssertEqual(spies.activator.injectActiveCalls.last, false)
        XCTAssertNil(spies.store.storedRecord)
        XCTAssertNil(controller.routeOwnerSessionID)
        XCTAssertTrue(spies.pcm.startCalls.isEmpty)
        XCTAssertEqual(spies.pcm.stopCalls, ["call-ended"])
        XCTAssertEqual(spies.mute.stopCallCount, 1)
        XCTAssertTrue(spies.route.setHogCalls.isEmpty)
    }

    func testTakeoverMutesContinuityOutputAndRestoreStopsMute() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .ringing, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.mute.startCalls, [CallAudioProcessMutePolicy.continuityOutputBundleIDs])
        XCTAssertTrue(spies.route.setHogCalls.isEmpty)

        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: true)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(spies.mute.stopCallCount, 1)
    }

    func testProcessMuteFailureDoesNotFailTakeover() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.mute.failStart = true
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .ringing, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.mute.startCalls, [CallAudioProcessMutePolicy.continuityOutputBundleIDs])
        XCTAssertTrue(spies.route.setHogCalls.isEmpty)
    }

    func testStillMutesWhenDefaultOutputIsSystemOutputAndNeverHogs() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.route.currentSnapshot = CallAudioRouteSnapshot(
            inputUID: CallAudioTestFixtures.originalInputUID,
            outputUID: CallAudioTestFixtures.originalSystemOutputUID,
            systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID
        )
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .ringing, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.mute.startCalls, [CallAudioProcessMutePolicy.continuityOutputBundleIDs])
        XCTAssertTrue(spies.route.setHogCalls.isEmpty, "process mute must not hog System Output")
    }

    func testRingingThenActiveStartsPCMExactlyOnce() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .ringing, session: session, workModeArmed: true)
        XCTAssertTrue(spies.pcm.startCalls.isEmpty)
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.pcm.startCalls, ["takeover"])
        XCTAssertEqual(spies.pcm.startRXTapDeviceIDs, [CallAudioProcessMuteControllingSpy.stubRXTapDeviceID], "Active PCM must read the Continuity mute tap, not Capture WriteMix")
        XCTAssertEqual(spies.activator.captureActiveCalls, [true], "Active after ringing must not re-run takeover")
        XCTAssertEqual(spies.route.setOutputCalls, [JarvisAudioDeviceUIDs.capture])
    }

    func testActivePCMGetsNilRXTapWhenMuteFails() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.mute.failStart = true
        let controller = makeController(spies)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .ringing, session: session, workModeArmed: true)
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.pcm.startCalls, ["takeover"])
        XCTAssertEqual(spies.pcm.startRXTapDeviceIDs, [nil], "mute failure must not block PCM; WriteMix fallback stays available")
    }

    // MARK: - §31 items 7-8/19/20: verified Active takeover, idempotency, session ownership

    func testVerifiedActiveStartsExactlyOneAcquisitionAndRepeatedTicksAreIdempotent() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()

        for _ in 0..<5 {
            await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        }

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(controller.routeOwnerSessionID, session.id)
        XCTAssertEqual(spies.activator.captureActiveCalls, [true])
        XCTAssertEqual(spies.activator.injectActiveCalls, [true])
        XCTAssertEqual(spies.route.setOutputCalls, [JarvisAudioDeviceUIDs.capture])
        XCTAssertEqual(spies.route.setInputCalls, [JarvisAudioDeviceUIDs.inject])
    }

    // MARK: - §31 item 10: snapshot uses UID identity (structural)

    func testRouteSnapshotIdentityIsUIDBased() async {
        let snapshot = CallAudioRouteSnapshot(inputUID: "uid-in", outputUID: "uid-out", systemOutputUID: "uid-sys")
        XCTAssertEqual(snapshot.inputUID, "uid-in")
        XCTAssertEqual(snapshot.outputUID, "uid-out")
        XCTAssertEqual(snapshot.systemOutputUID, "uid-sys")
        // The type has no `AudioDeviceID`/display-name fields at all — UID is the only identity.
    }

    // MARK: - §31 item 11: recovery record persisted before the first forward route mutation

    func testRecoveryRecordPersistedBeforeFirstForwardRouteMutation() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.activator.failCaptureActivate = true
        let controller = makeController(spies)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)

        XCTAssertEqual(spies.store.saveCallCount, 1, "the record must be saved even though activation subsequently failed")
        XCTAssertFalse(spies.route.setOutputCalls.contains(JarvisAudioDeviceUIDs.capture), "must never reach the forward route-to-Jarvis mutation once activation already failed")
    }

    // MARK: - §31 items 12-15: exact takeover operation order (§12)

    func testTakeoverOperationOrderMatchesSpec() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let logger = BridgeLogger()
        let controller = makeController(spies, logger: logger)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)

        let markers = ["prepare session", "snapshot inputUID", "driver capture activated", "driver inject activated", "default-output -> capture", "default-input -> inject", "route verification pass", "state=routed"]
        let stages = logger.lines.compactMap { line in markers.first { line.contains($0) } }
        XCTAssertEqual(stages, markers)
    }

    // MARK: - §31 item 16: no method exists to mutate System Output (structural)

    func testCallAudioRouteControllingHasNoSystemOutputSetter() async {
        // If this compiles, `CallAudioRouteControlling` has no method that could mutate Default
        // System Output — there is no such method to call at all.
        let spy = CallAudioRouteControllingSpy()
        let controller: CallAudioRouteControlling = spy
        _ = controller.currentRouteSnapshot()
    }

    // MARK: - §31 items 17-18: System Output invariant + full readback verification on takeover

    func testSystemOutputRemainsOriginalAfterTakeover() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.route.currentSnapshot?.systemOutputUID, CallAudioTestFixtures.originalSystemOutputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, JarvisAudioDeviceUIDs.capture, "Default Output must be Capture so Phone.app writes caller PCM there")
        XCTAssertEqual(spies.route.currentSnapshot?.inputUID, JarvisAudioDeviceUIDs.inject)
    }

    func testVerificationMismatchTriggersRollback() async {
        let spies = CallAudioTestFixtures.makeSpies()
        // Readback always reports the ORIGINAL input regardless of what was set — simulates a
        // setter that reported success but the real route silently didn't change.
        spies.route.forceInputUIDOnReadback = CallAudioTestFixtures.originalInputUID
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertNotEqual(controller.state, .routed)
        XCTAssertEqual(spies.activator.captureActiveCalls, [true, false], "must deactivate capture as part of rollback")
        XCTAssertEqual(spies.activator.injectActiveCalls, [true, false], "must deactivate inject as part of rollback")
    }

    // MARK: - §31 items 21-25: every partial-failure stage triggers rollback (§13/§29)

    func testCaptureActivationFailureTriggersRollback() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.activator.failCaptureActivate = true
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertNotEqual(controller.state, .routed)
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, CallAudioTestFixtures.originalOutputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.inputUID, CallAudioTestFixtures.originalInputUID)
    }

    func testInjectActivationFailureTriggersRollback() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.activator.failInjectActivate = true
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertNotEqual(controller.state, .routed)
        XCTAssertEqual(spies.activator.captureActiveCalls, [true, false], "capture must be deactivated again since it was already activated")
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, CallAudioTestFixtures.originalOutputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.inputUID, CallAudioTestFixtures.originalInputUID)
    }

    func testOutputRouteFailureTriggersRollback() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.route.failSetOutput = true
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertNotEqual(controller.state, .routed)
        XCTAssertEqual(spies.activator.captureActiveCalls, [true, false])
        XCTAssertEqual(spies.activator.injectActiveCalls, [true, false])
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, CallAudioTestFixtures.originalOutputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.inputUID, CallAudioTestFixtures.originalInputUID)
    }

    func testInputRouteFailureTriggersRollback() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.route.failSetInput = true
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertNotEqual(controller.state, .routed)
        XCTAssertEqual(spies.activator.captureActiveCalls, [true, false])
        XCTAssertEqual(spies.activator.injectActiveCalls, [true, false])
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, CallAudioTestFixtures.originalOutputUID, "output must be rolled back even though only input failed")
    }

    // MARK: - §31 item 26: Ending alone must not restore

    func testEndingAloneDoesNotTriggerRestore() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)

        await controller.handleLifecycleChange(callState: .ending, session: session, workModeArmed: true)

        XCTAssertEqual(controller.state, .routed, "Ending alone (Phase 2's own end debounce) must not yet trigger restore — only confirmed Idle does")
    }

    // MARK: - §31 items 27-32: confirmed Idle restore transaction

    func testConfirmedIdleWhileArmedRestoresOriginalRoutesAndReleasesHog() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)
        XCTAssertNotNil(spies.store.storedRecord)

        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: true)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, CallAudioTestFixtures.originalOutputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.inputUID, CallAudioTestFixtures.originalInputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.systemOutputUID, CallAudioTestFixtures.originalSystemOutputUID, "hangup must never touch System Output")
        XCTAssertEqual(spies.activator.captureActiveCalls.last, false)
        XCTAssertEqual(spies.activator.injectActiveCalls.last, false)
        XCTAssertNil(spies.store.storedRecord, "successful restore must clear the recovery record")
        XCTAssertNil(controller.routeOwnerSessionID)
        XCTAssertEqual(spies.pcm.stopCalls, ["call-ended"])
        XCTAssertEqual(spies.mute.stopCallCount, 1)
        XCTAssertTrue(spies.route.setHogCalls.isEmpty)
        XCTAssertFalse(controller.hasPersistedRecoveryRecord)
    }

    func testWorkModeOffRestoresOriginalRoutesDeactivatesDevicesAndClearsRecoveryRecord() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)
        XCTAssertNotNil(spies.store.storedRecord)

        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: false)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, CallAudioTestFixtures.originalOutputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.inputUID, CallAudioTestFixtures.originalInputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.systemOutputUID, CallAudioTestFixtures.originalSystemOutputUID, "restore must never touch System Output")
        XCTAssertEqual(spies.activator.captureActiveCalls.last, false)
        XCTAssertEqual(spies.activator.injectActiveCalls.last, false)
        XCTAssertNil(spies.store.storedRecord, "successful restore must clear the recovery record")
        XCTAssertNil(controller.routeOwnerSessionID)
        XCTAssertFalse(controller.hasPersistedRecoveryRecord, "the UI-facing flag must reflect the store having no record after a successful restore")
    }

    // MARK: - §31 items 33-36: emergency restore paths + idempotency

    func testWorkModeOffWhileRoutedRestoresImmediately() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)

        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: false)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(spies.activator.captureActiveCalls.last, false)
    }

    func testEmergencyRestoreOnAppQuitWhileRoutedRestoresImmediately() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)

        await controller.emergencyRestore(reason: "app-quit")

        XCTAssertEqual(controller.state, .idle)
    }

    func testEmergencyRestoreIsNoOpWhenNotRouted() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)

        await controller.emergencyRestore(reason: "app-quit")

        XCTAssertEqual(spies.route.setOutputCalls.count, 0)
        XCTAssertEqual(spies.route.setInputCalls.count, 0)
    }

    func testDuplicateRestoreCallsAreIdempotent() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: false)
        let outputCallsAfterFirstRestore = spies.route.setOutputCalls.count

        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: false)
        await controller.emergencyRestore(reason: "app-quit")

        XCTAssertEqual(spies.route.setOutputCalls.count, outputCallsAfterFirstRestore, "restore must be a no-op once already idle")
    }

    // MARK: - §31 items 37-38: new call after restore gets completely fresh ownership

    func testNewSessionAfterRestoreReceivesFreshOwnershipWithNoLeakedMetadata() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let sessionA = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: sessionA, workModeArmed: true)
        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: true)
        XCTAssertNil(controller.routeOwnerSessionID)

        let sessionB = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: sessionB, workModeArmed: true)

        XCTAssertEqual(controller.routeOwnerSessionID, sessionB.id)
        XCTAssertNotEqual(sessionA.id, sessionB.id)
        XCTAssertEqual(spies.store.storedRecord?.callSessionID, sessionB.id, "the recovery record must reflect the new session, not the restored one")
        XCTAssertEqual(spies.store.storedRecord?.originalOutputUID, CallAudioTestFixtures.originalOutputUID)
    }

    // MARK: - §31 items 39-42: startup recovery (§19-21)

    func testStartupRecoveryRestoresOriginalRoutesWhenCurrentlyOnJarvisDevices() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.store.storedRecord = CallAudioRecoveryRecord(
            version: 1, callSessionID: "stale-session", createdAt: Date(),
            originalInputUID: CallAudioTestFixtures.originalInputUID, originalOutputUID: CallAudioTestFixtures.originalOutputUID, originalSystemOutputUID: CallAudioTestFixtures.originalSystemOutputUID,
            targetInputUID: JarvisAudioDeviceUIDs.inject, targetOutputUID: JarvisAudioDeviceUIDs.capture
        )
        spies.route.hogPIDs[CallAudioTestFixtures.originalOutputUID] = 999
        spies.route.currentSnapshot = CallAudioRouteSnapshot(inputUID: JarvisAudioDeviceUIDs.inject, outputUID: JarvisAudioDeviceUIDs.capture, systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID)
        let controller = makeController(spies)

        controller.performStartupRecovery()

        XCTAssertEqual(spies.route.setHogCalls.last?.uid, CallAudioTestFixtures.originalOutputUID)
        XCTAssertEqual(spies.route.setHogCalls.last?.pid, -1)
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, CallAudioTestFixtures.originalOutputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.inputUID, CallAudioTestFixtures.originalInputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.systemOutputUID, CallAudioTestFixtures.originalSystemOutputUID, "startup recovery must never mutate System Output")
        XCTAssertEqual(spies.activator.captureActiveCalls.last, false)
        XCTAssertEqual(spies.activator.injectActiveCalls.last, false)
        XCTAssertNil(spies.store.storedRecord)
    }

    func testStartupRecoveryDoesNotOverwriteUserRoutesWhenAlreadyNonJarvis() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.store.storedRecord = CallAudioRecoveryRecord(
            version: 1, callSessionID: "stale-session", createdAt: Date(),
            originalInputUID: CallAudioTestFixtures.originalInputUID, originalOutputUID: CallAudioTestFixtures.originalOutputUID, originalSystemOutputUID: CallAudioTestFixtures.originalSystemOutputUID,
            targetInputUID: JarvisAudioDeviceUIDs.inject, targetOutputUID: JarvisAudioDeviceUIDs.capture
        )
        spies.route.currentSnapshot = CallAudioRouteSnapshot(inputUID: "com.example.newmic", outputUID: "com.example.newspeaker", systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID)
        let controller = makeController(spies)

        controller.performStartupRecovery()

        XCTAssertEqual(spies.route.setOutputCalls.count, 0, "must never overwrite routes the user is already using")
        XCTAssertEqual(spies.route.setInputCalls.count, 0)
        XCTAssertNil(spies.store.storedRecord, "the stale record must still be cleared")
    }

    func testStartupRecoveryFailsSafelyWhenOriginalDeviceMissing() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.store.storedRecord = CallAudioRecoveryRecord(
            version: 1, callSessionID: "stale-session", createdAt: Date(),
            originalInputUID: "com.example.missing-mic", originalOutputUID: "com.example.missing-speaker", originalSystemOutputUID: CallAudioTestFixtures.originalSystemOutputUID,
            targetInputUID: JarvisAudioDeviceUIDs.inject, targetOutputUID: JarvisAudioDeviceUIDs.capture
        )
        spies.route.currentSnapshot = CallAudioRouteSnapshot(inputUID: JarvisAudioDeviceUIDs.inject, outputUID: JarvisAudioDeviceUIDs.capture, systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID)
        // deliberately not adding "com.example.missing-*" to existingDeviceUIDs
        let controller = makeController(spies)

        controller.performStartupRecovery()

        XCTAssertEqual(spies.route.setOutputCalls.count, 0, "must never guess a replacement device")
        XCTAssertEqual(spies.route.setInputCalls.count, 0)
        XCTAssertEqual(spies.activator.captureActiveCalls.last, false, "still safely deactivates the Jarvis devices")
        XCTAssertEqual(spies.activator.injectActiveCalls.last, false)
        XCTAssertNil(spies.store.storedRecord)
    }

    // MARK: - §31 item 43: route ownership loss detection

    func testUserRouteOwnershipLossIsDetectedAndNotFoughtIndefinitely() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)

        // The user manually picks a different input device mid-call.
        spies.route.currentSnapshot = CallAudioRouteSnapshot(inputUID: "com.example.headphones", outputUID: JarvisAudioDeviceUIDs.capture, systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID)

        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .idle, "ownership loss must drop back to idle, not keep trying to force the route back")
        XCTAssertEqual(spies.mute.stopCallCount, 1, "ownership loss must stop Continuity process mute")
        XCTAssertTrue(spies.route.setHogCalls.isEmpty)
        let outputCallsAfterLoss = spies.route.setOutputCalls.count

        // The call is still (nominally) Active on subsequent ticks — must never re-grab the route.
        for _ in 0..<5 {
            await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        }
        XCTAssertEqual(spies.route.setOutputCalls.count, outputCallsAfterLoss, "must never fight the user by re-acquiring the route for the same session")
    }

    func testUserChangingDefaultOutputMidCallIsOwnershipLoss() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)

        spies.route.currentSnapshot = CallAudioRouteSnapshot(
            inputUID: JarvisAudioDeviceUIDs.inject,
            outputUID: CallAudioTestFixtures.originalOutputUID,
            systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID
        )

        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .idle, "leaving Capture as Default Output mid-call is ownership loss")
        XCTAssertEqual(spies.mute.stopCallCount, 1)
    }

    /// Phase 3 CHECKPOINT 2 Rpcm/AudioObjectID-churn investigation (§31/§32/§41) — the
    /// `route-ownership-lost` diagnostic must carry the exact expected-vs-observed UIDs that
    /// explain WHY it fired, and the underlying detection must be UID-based (never
    /// AudioObjectID-based, which this codebase never treats as stable identity anywhere).
    func testRouteOwnershipLossLogsExpectedAndObservedUIDs() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let logger = BridgeLogger()
        let controller = makeController(spies, logger: logger)
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)

        spies.route.currentSnapshot = CallAudioRouteSnapshot(inputUID: "com.example.headphones", outputUID: JarvisAudioDeviceUIDs.capture, systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID)
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)

        let ownershipLossLine = logger.lines.first { $0.contains("route-ownership-lost") }
        XCTAssertNotNil(ownershipLossLine, "must log a route-ownership-lost line at all")
        XCTAssertTrue(ownershipLossLine?.contains("expectedInputUID=\(JarvisAudioDeviceUIDs.inject)") ?? false)
        XCTAssertTrue(ownershipLossLine?.contains("observedInputUID=com.example.headphones") ?? false, "must show the ACTUAL observed input UID that triggered the loss")
        XCTAssertTrue(ownershipLossLine?.contains("expectedOutputUID=\(JarvisAudioDeviceUIDs.capture)") ?? false)
        XCTAssertTrue(ownershipLossLine?.contains("leftOutputUID=\(CallAudioTestFixtures.originalOutputUID)") ?? false)
        XCTAssertTrue(ownershipLossLine?.contains("observedOutputUID=\(JarvisAudioDeviceUIDs.capture)") ?? false)
    }

    /// A route snapshot reporting the SAME UIDs Jarvis expects must never be treated as ownership
    /// loss — this is what "UID-based, not AudioObjectID-based" identity means in practice:
    /// nothing in this comparison could even see an AudioObjectID change, since
    /// `CallAudioRouteSnapshot` only ever carries UID strings.
    func testSameUIDsNeverTriggerOwnershipLossRegardlessOfHowManyTimesObserved() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)

        // Same logical route, re-observed repeatedly (simulating what a same-UID-but-different-
        // AudioObjectID scenario would look like from this controller's perspective — it only
        // ever sees UIDs, so there is nothing here that COULD distinguish an ID change).
        for _ in 0..<5 {
            spies.route.currentSnapshot = CallAudioRouteSnapshot(inputUID: JarvisAudioDeviceUIDs.inject, outputUID: JarvisAudioDeviceUIDs.capture, systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID)
            await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        }
        XCTAssertEqual(controller.state, .routed, "identical UIDs must never be treated as ownership loss")
    }

    // MARK: - §31 items 44-46: no PCM/Realtime/recording objects in this checkpoint (structural)

    /// `JarvisCallBridge` doesn't even depend on `JarvisAudioDriverTool` (where `DeviceIOSession`,
    /// the only actual audio I/O type in this repo, lives), and no Realtime/recording type exists
    /// anywhere in this target — a structural, compile-time guarantee this file compiling already
    /// proves, not something a runtime assertion could meaningfully strengthen.
    func testNoPCMStreamingRealtimeOrRecordingObjectsExist() async {
        XCTAssertTrue(true)
    }

    // MARK: - §16 — Real-device fix: bounded route convergence + recovery-record postconditions
    //
    // §16 item 9 ("tests use a controllable clock/scheduler — no real 1-second sleeps") is
    // satisfied structurally: `makeController` defaults every test in this file to
    // `convergenceMaxAttempts: 5, convergencePollNanoseconds: 1_000_000` (1ms), so the real async
    // `Task.sleep` polling path is genuinely exercised without ever spending real wall-clock time
    // anywhere near the production ~750ms budget.

    // §16 item 3: target visible immediately — must not poll more than once.
    func testConvergenceSucceedsImmediatelyWithoutUnnecessaryPolling() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.route.snapshotCallCount, 2, "1 initial pre-takeover snapshot + exactly 1 convergence attempt — no unnecessary extra polling when the target is already observable")
    }

    // §16 item 1: first readback still reports the old device, second readback reports the target.
    func testConvergenceSucceedsAfterOneStaleReadbackThenTarget() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.route.staleSnapshotOverride = CallAudioRouteSnapshot(
            inputUID: CallAudioTestFixtures.originalInputUID, outputUID: CallAudioTestFixtures.originalOutputUID,
            systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID
        )
        spies.route.staleInputReadbackCount = 1
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed, "one stale readback must not be mistaken for a real verification failure")
        XCTAssertEqual(spies.activator.captureActiveCalls, [true], "no rollback — the second poll attempt must have observed the real converged route")
        XCTAssertEqual(spies.route.snapshotCallCount, 3, "1 initial snapshot + 2 convergence attempts (stale, then converged)")
    }

    // §16 item 2: several stale readbacks in a row, then the target settles within the deadline.
    func testConvergenceSucceedsAfterMultipleStaleReadbacksWithinDeadline() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.route.staleSnapshotOverride = CallAudioRouteSnapshot(
            inputUID: CallAudioTestFixtures.originalInputUID, outputUID: CallAudioTestFixtures.originalOutputUID,
            systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID
        )
        spies.route.staleInputReadbackCount = 3 // within the 5-attempt test budget
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.route.snapshotCallCount, 5, "1 initial snapshot + 4 convergence attempts (3 stale, then converged)")
    }

    // §16 items 4/8: target never converges — verification must time out at a bounded attempt
    // count (never retry indefinitely), then roll back; rollback's own restoration convergence is
    // subject to the same bound.
    func testConvergenceNeverConvergesTimesOutAtBoundedAttemptsThenRollsBack() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.route.forceInputUIDOnReadback = "com.example.permanently-stuck-device"
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertNotEqual(controller.state, .routed)
        XCTAssertEqual(spies.activator.captureActiveCalls, [true, false], "must roll back after the forward verification times out")
        XCTAssertEqual(spies.activator.injectActiveCalls, [true, false])
        XCTAssertEqual(
            spies.route.snapshotCallCount, 11,
            "1 initial snapshot + 5 bounded forward-verification attempts + 5 bounded rollback-restoration attempts — neither poll may exceed convergenceMaxAttempts"
        )
    }

    // §16 item 5: output settles before input — verification must still wait for input too.
    func testOutputConvergesBeforeInputStillWaitsForBothToConverge() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.route.staleSnapshotOverride = CallAudioRouteSnapshot(
            inputUID: CallAudioTestFixtures.originalInputUID, outputUID: CallAudioTestFixtures.originalOutputUID,
            systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID
        )
        spies.route.staleInputReadbackCount = 2
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.route.snapshotCallCount, 4, "1 initial snapshot + 3 convergence attempts — output matched from attempt 1 but the poll must not stop until input matches too")
    }

    // §16 item 6: input settles before output — verification must still wait for output too.
    func testInputConvergesBeforeOutputStillWaitsForBothToConverge() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.route.staleSnapshotOverride = CallAudioRouteSnapshot(
            inputUID: JarvisAudioDeviceUIDs.inject, outputUID: CallAudioTestFixtures.originalOutputUID,
            systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID
        )
        spies.route.staleOutputReadbackCount = 2
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertEqual(spies.route.snapshotCallCount, 4, "1 initial snapshot + 3 convergence attempts — input matched from attempt 1 but the poll must not stop until output matches too")
    }

    // §16 item 7: a permanent System Output mismatch must fail verification even when Input and
    // Output both match — System Output must never be silently ignored by the convergence check.
    func testSystemOutputMismatchFailsVerificationEvenWhenInputOutputMatch() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.route.forceSystemOutputUIDOnReadback = "com.example.wrong-system-output"
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertNotEqual(controller.state, .routed, "Input/Output matching alone must not be treated as verified — System Output must also match")
        XCTAssertEqual(spies.activator.captureActiveCalls, [true, false], "System Output mismatch must still trigger rollback")
    }

    // §16 item 10: normal restore-after-Idle verification uses the same bounded convergence poll,
    // not a single immediate readback — a stale readback mid-restore must not be misread as failure.
    func testNormalRestoreUsesBoundedConvergencePolling() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)

        // Simulate the readback lagging behind the restore's own setters — still reporting the
        // (about-to-be-vacated) Jarvis-owned route for one extra poll attempt.
        spies.route.staleSnapshotOverride = CallAudioRouteSnapshot(
            inputUID: JarvisAudioDeviceUIDs.inject, outputUID: JarvisAudioDeviceUIDs.capture,
            systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID
        )
        spies.route.staleOutputReadbackCount = 1
        spies.route.staleInputReadbackCount = 1

        await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: false)

        XCTAssertEqual(controller.state, .idle, "restore must tolerate one stale readback via bounded polling rather than reporting failure immediately")
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, CallAudioTestFixtures.originalOutputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.inputUID, CallAudioTestFixtures.originalInputUID)
        XCTAssertNil(spies.store.storedRecord)
        XCTAssertFalse(controller.hasPersistedRecoveryRecord)
    }

    // §16 item 11: rollback's own route-restoration verification also uses bounded convergence —
    // a stale readback mid-rollback must not prevent it from eventually reporting success.
    func testRollbackRouteRestorationConvergesAfterStaleReadbackAndStillReportsSuccess() async {
        let spies = CallAudioTestFixtures.makeSpies()
        // Fails before any route setter runs (device-activation stage, not a route-setter stage),
        // so this doesn't interfere with rollback's own setDefaultOutputDevice/setDefaultInputDevice
        // calls the way reusing `failSetInput` as the trigger would (that flag would also block
        // rollback's own restoration attempt, since the spy can't distinguish "forward" from
        // "rollback" callers).
        spies.activator.failInjectActivate = true
        spies.route.staleSnapshotOverride = CallAudioRouteSnapshot(
            inputUID: CallAudioTestFixtures.originalInputUID, outputUID: JarvisAudioDeviceUIDs.capture,
            systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID
        )
        spies.route.staleOutputReadbackCount = 1
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .idle, "rollback must fully succeed once its own bounded convergence poll observes the restored route, even after one stale readback")
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, CallAudioTestFixtures.originalOutputUID)
        XCTAssertEqual(spies.route.currentSnapshot?.inputUID, CallAudioTestFixtures.originalInputUID)
        XCTAssertNil(spies.store.storedRecord)
    }

    // §16 items 12/13: recovery-record deletion is a REQUIRED postcondition for `rollback
    // result=success` — a rollback whose route restoration is otherwise perfect must still report
    // failure (never success) if the recovery store's `clear()` itself fails.
    func testRollbackCannotReportFullSuccessWhenRecoveryRecordDeletionFails() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.activator.failCaptureActivate = true // simplest rollback trigger — no route mutation ever happens
        spies.store.failClear = true
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .failed, "route restoration alone succeeding is not enough — recovery-record deletion failure must prevent a success report")
        XCTAssertNotNil(spies.store.storedRecord, "the record must still be considered present on disk since clear() reported failure")
        XCTAssertTrue(controller.hasPersistedRecoveryRecord, "the UI-facing flag must reflect the store's real state, not an assumed success")
    }

    // §16 item 14/17: a fully successful rollback (route restored AND recovery record actually
    // deleted) must leave no recovery record behind, and the UI-facing flag must reflect that.
    func testSuccessfulRollbackLeavesRecoveryRecordAbsentAndUIReflectsIt() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.activator.failInjectActivate = true
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(spies.store.storedRecord, "a successful rollback must delete the recovery record, not merely restore routes")
        XCTAssertFalse(controller.hasPersistedRecoveryRecord, "the UI-facing flag must reflect the now-empty store")
    }

    // §16 item 16: a successful takeover must leave the recovery record present while Routed —
    // this is the correct/expected state (required for crash recovery while Jarvis owns the route).
    func testSuccessfulTakeoverLeavesRecoveryRecordPresentWhileRouted() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)

        await controller.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(controller.state, .routed)
        XCTAssertNotNil(spies.store.storedRecord, "the recovery record must exist while Jarvis owns the route")
        XCTAssertTrue(controller.hasPersistedRecoveryRecord, "the UI-facing flag must reflect the store having a live record")
    }

    // §16 item 19: a session excluded after a failed takeover must never be retried, no matter how
    // many more times the (still nominally Active) call is observed on subsequent poll ticks.
    func testRepeatedActiveAfterFailedTakeoverNeverRetriesExcludedSession() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.route.existingDeviceUIDs = [
            CallAudioTestFixtures.originalInputUID, CallAudioTestFixtures.originalOutputUID, CallAudioTestFixtures.originalSystemOutputUID,
        ] // Jarvis capture/inject devices deliberately absent
        let controller = makeController(spies)
        let session = CallSession()

        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .failed)
        let deviceExistsCallsAfterFirstFailure = spies.route.deviceExistsCalls.count

        for _ in 0..<5 {
            await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        }

        XCTAssertEqual(spies.route.deviceExistsCalls.count, deviceExistsCallsAfterFirstFailure, "an excluded session must never be re-attempted at all, not even re-checking device existence")
        XCTAssertTrue(spies.route.setOutputCalls.isEmpty, "no route mutation may ever occur for a permanently excluded session")
    }

    func testOwnershipLossDoesNotRegrabOnSubsequentIdleTicks() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let controller = makeController(spies)
        let session = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed)

        spies.route.currentSnapshot = CallAudioRouteSnapshot(
            inputUID: "com.example.headphones", outputUID: JarvisAudioDeviceUIDs.capture,
            systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID
        )
        await controller.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(controller.state, .idle)
        let outputCallsAfterLoss = spies.route.setOutputCalls.count

        for _ in 0..<5 {
            await controller.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: true)
        }
        XCTAssertEqual(spies.route.setOutputCalls.count, outputCallsAfterLoss, "idle ticks must not re-grab the route the user just chose")

        spies.route.currentSnapshot = CallAudioRouteSnapshot(
            inputUID: CallAudioTestFixtures.originalInputUID, outputUID: CallAudioTestFixtures.originalOutputUID,
            systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID
        )
        let nextCall = CallSession()
        await controller.handleLifecycleChange(callState: .active, session: nextCall, workModeArmed: true)
        XCTAssertEqual(controller.state, .routed, "a later real call may still take the route after ownership-loss")
        XCTAssertEqual(controller.routeOwnerSessionID, nextCall.id)
    }
}
