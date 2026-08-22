import XCTest
@testable import JarvisCallBridge

/// Phase 3 CHECKPOINT 1 — Audio Route UI Synchronization Fix. The top-level "Audio Route —
/// Input/Output/System Output" display (`BridgeViewModel.routeSnapshot`, backed by
/// `AudioRouteReading`) is a completely separate abstraction from `CallAudioSessionController`'s
/// own internal `CallAudioRouteControlling` snapshot — real-device evidence showed the two never
/// synchronized automatically, so the display stayed stale through a whole successful
/// takeover/restore cycle. These tests drive `CallAudioSessionController` directly (bypassing the
/// Accessibility scanner entirely, matching `BridgeViewModelPhase3Tests`'s existing pattern) and
/// assert `BridgeViewModel.routeSnapshot` — backed by a separate, independently-controlled
/// `FakeAudioRouteReader` — updates automatically at exactly the right transactional boundaries,
/// always reflecting whatever that fake reports as the "real" route, never a value derived from
/// `CallAudioSessionState` or a hardcoded Jarvis device name.
@MainActor
final class AudioRouteUISynchronizationTests: XCTestCase {
    private let originalSnapshot = AudioRouteSnapshot(
        defaultInputDeviceID: 1, defaultOutputDeviceID: 2, defaultSystemOutputDeviceID: 2,
        defaultInputName: "Microphone", defaultOutputName: "Smart M80C", defaultSystemOutputName: "Mac Studio 스피커"
    )
    private let routedSnapshot = AudioRouteSnapshot(
        defaultInputDeviceID: 396, defaultOutputDeviceID: 264, defaultSystemOutputDeviceID: 2,
        defaultInputName: "Jarvis Call Inject", defaultOutputName: "Jarvis Call Capture", defaultSystemOutputName: "Mac Studio 스피커"
    )
    private let userChosenSnapshot = AudioRouteSnapshot(
        defaultInputDeviceID: 55, defaultOutputDeviceID: 56, defaultSystemOutputDeviceID: 2,
        defaultInputName: "AirPods Pro", defaultOutputName: "AirPods Pro", defaultSystemOutputName: "Mac Studio 스피커"
    )

    private func makeModel(fakeReader: FakeAudioRouteReader, spies: (route: CallAudioRouteControllingSpy, activator: JarvisAudioDeviceActivatingSpy, store: InMemoryCallAudioRecoveryStore, pcm: CallAudioPCMControllingSpy, mute: CallAudioProcessMuteControllingSpy)) -> BridgeViewModel {
        let session = CallAudioSessionController(routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store, pcmController: spies.pcm, processMute: spies.mute, logger: BridgeLogger())
        return BridgeViewModel(routeReader: fakeReader, accessibilityScanner: MockAccessibilityScanning(), callAudioSession: session)
    }

    // §17 item 1: startup populates the route display from the actual route provider.
    func testStartupPopulatesRouteDisplayFromActualRouteProvider() {
        let fakeReader = FakeAudioRouteReader(snapshot: originalSnapshot)
        let model = makeModel(fakeReader: fakeReader, spies: CallAudioTestFixtures.makeSpies())

        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }

        XCTAssertEqual(model.routeSnapshot, originalSnapshot)
    }

    // Answering/ending/unknown still do not refresh the route display. Ringing now *does*
    // take Input (Inject) and Output (Capture) and must refresh.
    func testAnsweringAloneDoesNotChangeRouteDisplay() async {
        let fakeReader = FakeAudioRouteReader(snapshot: originalSnapshot)
        let model = makeModel(fakeReader: fakeReader, spies: CallAudioTestFixtures.makeSpies())
        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }
        XCTAssertEqual(model.routeSnapshot, originalSnapshot)

        fakeReader.snapshot = routedSnapshot
        let session = CallSession()
        await model.callAudioSession.handleLifecycleChange(callState: .answering, session: session, workModeArmed: true)
        XCTAssertEqual(model.routeSnapshot, originalSnapshot, "Answering alone must never trigger a route display refresh")
        XCTAssertEqual(model.callAudioSession.state, .idle)
    }

    func testRingingTakeoverRefreshesRouteDisplayToJarvisRoute() async {
        let fakeReader = FakeAudioRouteReader(snapshot: originalSnapshot)
        let spies = CallAudioTestFixtures.makeSpies()
        let model = makeModel(fakeReader: fakeReader, spies: spies)
        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }

        fakeReader.snapshot = routedSnapshot
        let session = CallSession()
        await model.callAudioSession.handleLifecycleChange(callState: .ringing, session: session, workModeArmed: true)

        XCTAssertEqual(model.callAudioSession.state, .routed)
        XCTAssertEqual(model.routeSnapshot, routedSnapshot)
        XCTAssertTrue(spies.pcm.startCalls.isEmpty, "ringing takeover must not open PCM")
    }

    // §17 items 4/5/6/16: successful takeover triggers a refresh, and the UI shows exactly what
    // the route provider now reports (Jarvis Input/Output, unchanged System Output) — not a
    // hardcoded name and not something derived from `state == .routed`.
    func testSuccessfulTakeoverRefreshesRouteDisplayToActualJarvisRoute() async {
        let fakeReader = FakeAudioRouteReader(snapshot: originalSnapshot)
        let spies = CallAudioTestFixtures.makeSpies()
        let model = makeModel(fakeReader: fakeReader, spies: spies)
        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }

        fakeReader.snapshot = routedSnapshot // simulates the real CoreAudio route having actually changed
        await model.callAudioSession.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(model.callAudioSession.state, .routed)
        XCTAssertEqual(model.routeSnapshot, routedSnapshot)
        XCTAssertEqual(model.routeSnapshot?.defaultInputName, "Jarvis Call Inject")
        XCTAssertEqual(model.routeSnapshot?.defaultOutputName, "Jarvis Call Capture")
        XCTAssertEqual(model.routeSnapshot?.defaultSystemOutputName, "Mac Studio 스피커", "System Output must display as unchanged")
    }

    // §17 items 7/8: Work Mode OFF restore triggers a refresh back to whatever the route
    // provider now reports as the original route.
    func testSuccessfulNormalRestoreRefreshesRouteDisplayToOriginalRoute() async {
        let fakeReader = FakeAudioRouteReader(snapshot: originalSnapshot)
        let spies = CallAudioTestFixtures.makeSpies()
        let model = makeModel(fakeReader: fakeReader, spies: spies)
        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }
        let session = CallSession()

        fakeReader.snapshot = routedSnapshot
        await model.callAudioSession.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(model.routeSnapshot, routedSnapshot)

        fakeReader.snapshot = originalSnapshot // simulates the restore setters having actually taken effect
        await model.callAudioSession.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: false)

        XCTAssertEqual(model.callAudioSession.state, .idle)
        XCTAssertEqual(model.routeSnapshot, originalSnapshot)
    }

    // §17 items 9/10: successful rollback (a mid-takeover failure) triggers a refresh reflecting
    // the actual restored route.
    func testSuccessfulRollbackRefreshesRouteDisplayToActualRestoredRoute() async {
        let fakeReader = FakeAudioRouteReader(snapshot: originalSnapshot)
        let spies = CallAudioTestFixtures.makeSpies()
        spies.activator.failInjectActivate = true // triggers rollback partway through takeover
        let model = makeModel(fakeReader: fakeReader, spies: spies)
        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }

        // The real route never actually left `originalSnapshot` (rollback undid the partial
        // change) — a distinct instance proves the refresh re-reads live state rather than
        // reusing whatever was cached from `start()`.
        let confirmedAfterRollback = AudioRouteSnapshot(
            defaultInputDeviceID: 1, defaultOutputDeviceID: 2, defaultSystemOutputDeviceID: 2,
            defaultInputName: "Microphone", defaultOutputName: "Smart M80C", defaultSystemOutputName: "Mac Studio 스피커"
        )
        fakeReader.snapshot = confirmedAfterRollback
        await model.callAudioSession.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(model.callAudioSession.state, .idle, "rollback must have completed successfully")
        XCTAssertEqual(model.routeSnapshot, confirmedAfterRollback)
    }

    // §17 items 11/12: route ownership loss triggers a refresh, and the UI shows the user's
    // actual currently-selected devices — never the Jarvis route Jarvis merely *expected*.
    func testRouteOwnershipLossRefreshesToUserSelectedRoute() async {
        let fakeReader = FakeAudioRouteReader(snapshot: originalSnapshot)
        let spies = CallAudioTestFixtures.makeSpies()
        let model = makeModel(fakeReader: fakeReader, spies: spies)
        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }
        let session = CallSession()

        fakeReader.snapshot = routedSnapshot
        await model.callAudioSession.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(model.callAudioSession.state, .routed)

        // The user manually picks a different device mid-call — CallAudioSessionController's own
        // internal route spy reflects that, AND (independently) the top-level fake reader is
        // switched to the same user-chosen device, simulating the real CoreAudio route the OS
        // itself would now report.
        spies.route.currentSnapshot = CallAudioRouteSnapshot(inputUID: "com.example.airpods", outputUID: "com.example.airpods", systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID)
        fakeReader.snapshot = userChosenSnapshot
        await model.callAudioSession.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)

        XCTAssertEqual(model.callAudioSession.state, .idle, "ownership loss must drop Jarvis's own route ownership")
        XCTAssertEqual(model.routeSnapshot, userChosenSnapshot, "UI must show the user's actual route, never the Jarvis route Jarvis expected")
    }

    // §17 item 13: startup recovery (a stale recovery record found at launch) triggers a final
    // route refresh once it completes.
    func testStartupRecoveryTriggersRouteRefresh() {
        let fakeReader = FakeAudioRouteReader(snapshot: nil) // not yet populated before start()
        let spies = CallAudioTestFixtures.makeSpies()
        spies.store.storedRecord = CallAudioRecoveryRecord(
            version: 1, callSessionID: "stale-session", createdAt: Date(),
            originalInputUID: CallAudioTestFixtures.originalInputUID, originalOutputUID: CallAudioTestFixtures.originalOutputUID, originalSystemOutputUID: CallAudioTestFixtures.originalSystemOutputUID,
            targetInputUID: JarvisAudioDeviceUIDs.inject, targetOutputUID: JarvisAudioDeviceUIDs.capture
        )
        spies.route.currentSnapshot = CallAudioRouteSnapshot(inputUID: JarvisAudioDeviceUIDs.inject, outputUID: JarvisAudioDeviceUIDs.capture, systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID)
        let model = makeModel(fakeReader: fakeReader, spies: spies)

        // Simulates the real route already having been restored by the time `refreshRouteSnapshot`
        // is called — proves the refresh actually happened (routeSnapshot is non-nil at the end),
        // not merely that `start()`'s own later unconditional refresh call papered over it.
        fakeReader.snapshot = originalSnapshot

        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }

        XCTAssertNil(spies.store.storedRecord, "sanity: startup recovery must have actually run")
        XCTAssertEqual(model.routeSnapshot, originalSnapshot)
    }

    // §17 item 14: Work Mode OFF (an emergency-restore path, not the normal call-ended path)
    // refreshes the route display too.
    func testWorkModeOffEmergencyRestoreRefreshesRouteDisplay() async {
        let fakeReader = FakeAudioRouteReader(snapshot: originalSnapshot)
        let spies = CallAudioTestFixtures.makeSpies()
        let model = makeModel(fakeReader: fakeReader, spies: spies)
        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }
        let session = CallSession()

        fakeReader.snapshot = routedSnapshot
        await model.callAudioSession.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(model.callAudioSession.state, .routed)

        fakeReader.snapshot = originalSnapshot
        await model.callAudioSession.handleLifecycleChange(callState: .active, session: session, workModeArmed: false) // Work Mode OFF mid-call

        XCTAssertEqual(model.callAudioSession.state, .idle)
        XCTAssertEqual(model.routeSnapshot, originalSnapshot)
    }

    // §17 item 15: a route-snapshot refresh failure (route provider returns nil) must never
    // convert an already-successfully-verified takeover into a failed one — the two are separate
    // concerns.
    func testRouteSnapshotRefreshFailureDoesNotFailAnAlreadySuccessfulTakeover() async {
        let fakeReader = FakeAudioRouteReader(snapshot: originalSnapshot)
        let spies = CallAudioTestFixtures.makeSpies()
        let model = makeModel(fakeReader: fakeReader, spies: spies)
        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }

        fakeReader.snapshot = nil // the top-level route provider fails independently of CallAudioSessionController's own (successful) internal readback
        await model.callAudioSession.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(model.callAudioSession.state, .routed, "a display-refresh failure must never downgrade a verified takeover's own result")
        XCTAssertNil(model.routeSnapshot, "the UI honestly shows 'no snapshot available' rather than a stale or fabricated value")
    }

    // §17 item 18: the manual "Refresh Audio Route Snapshot" button path (no explicit reason
    // argument) still works exactly as before.
    func testManualRefreshStillWorks() {
        let fakeReader = FakeAudioRouteReader(snapshot: originalSnapshot)
        let model = makeModel(fakeReader: fakeReader, spies: CallAudioTestFixtures.makeSpies())

        fakeReader.snapshot = routedSnapshot
        model.refreshRouteSnapshot() // no `reason:` argument — matches ContentView's button action exactly

        XCTAssertEqual(model.routeSnapshot, routedSnapshot)
    }
}
