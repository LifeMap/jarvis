import XCTest
@testable import JarvisCallBridge

/// Phase 3 CHECKPOINT 2 RX investigation (§25/§26) — "Call Audio Driver" UI sync fix. Real-device
/// evidence showed the driver-status row could keep reading "Active" for up to 5 seconds after a
/// real, already-logged deactivation, because `AudioDriverStatus` only refreshed on its own
/// independent 5-second timer. The fix wires `audioDriver.refresh()` into the exact same
/// `onRouteMutated` boundary the already-fixed Audio Route UI sync uses (see
/// `AudioRouteUISynchronizationTests`) — these tests pin that wiring via `AudioDriverStatus`'s
/// test-only `refreshCount`, since `state` alone stays `.notInstalled` in this environment
/// regardless of how many times `refresh()` ran.
@MainActor
final class AudioDriverStatusUISynchronizationTests: XCTestCase {
    private func makeModel(spies: (route: CallAudioRouteControllingSpy, activator: JarvisAudioDeviceActivatingSpy, store: InMemoryCallAudioRecoveryStore, pcm: CallAudioPCMControllingSpy, mute: CallAudioProcessMuteControllingSpy)) -> BridgeViewModel {
        let session = CallAudioSessionController(routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store, pcmController: spies.pcm, processMute: spies.mute, logger: BridgeLogger())
        return BridgeViewModel(accessibilityScanner: MockAccessibilityScanning(), callAudioSession: session)
    }

    func testSuccessfulTakeoverRefreshesDriverStatus() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let model = makeModel(spies: spies)
        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }

        let baseline = model.audioDriver.refreshCount
        await model.callAudioSession.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(model.callAudioSession.state, .routed, "sanity: takeover must have actually succeeded")
        XCTAssertGreaterThan(model.audioDriver.refreshCount, baseline, "a successful takeover must refresh the driver-status row, not wait for the next 5s timer tick")
    }

    func testSuccessfulRestoreRefreshesDriverStatus() async {
        let spies = CallAudioTestFixtures.makeSpies()
        let model = makeModel(spies: spies)
        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }
        let session = CallSession()

        await model.callAudioSession.handleLifecycleChange(callState: .active, session: session, workModeArmed: true)
        XCTAssertEqual(model.callAudioSession.state, .routed)

        let baseline = model.audioDriver.refreshCount
        await model.callAudioSession.handleLifecycleChange(callState: .idle, session: nil, workModeArmed: false)

        XCTAssertEqual(model.callAudioSession.state, .idle, "sanity: restore/teardown must have actually completed — real deactivation already proven by CallAudioSessionControllerTests")
        XCTAssertGreaterThan(model.audioDriver.refreshCount, baseline, "restore (the exact real-device scenario that showed a stale 'Active' row) must refresh driver status immediately, not after up to 5s")
    }

    func testRollbackRefreshesDriverStatus() async {
        let spies = CallAudioTestFixtures.makeSpies()
        spies.activator.failInjectActivate = true // triggers rollback partway through takeover
        let model = makeModel(spies: spies)
        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }

        let baseline = model.audioDriver.refreshCount
        await model.callAudioSession.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)

        XCTAssertEqual(model.callAudioSession.state, .idle, "sanity: rollback must have completed")
        XCTAssertGreaterThan(model.audioDriver.refreshCount, baseline)
    }

    func testDriverStatusRefreshFailureDoesNotAffectCallAudioSessionState() async {
        // AudioDriverStatus.refresh() always succeeds-or-reports-notInstalled in this environment
        // (no real driver) — this test documents the required *independence*: `onRouteMutated`
        // calls `refreshRouteSnapshot` and `audioDriver.refresh()` as two unrelated, order-independent
        // presentation-layer calls, neither able to influence `callAudioSession.state`, which was
        // already finalized before the closure fires.
        let spies = CallAudioTestFixtures.makeSpies()
        let model = makeModel(spies: spies)
        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }

        await model.callAudioSession.handleLifecycleChange(callState: .active, session: CallSession(), workModeArmed: true)
        XCTAssertEqual(model.callAudioSession.state, .routed, "a UI-refresh call must never downgrade an already-successful takeover")
    }
}
