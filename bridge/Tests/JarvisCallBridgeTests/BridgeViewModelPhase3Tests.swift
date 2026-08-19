import XCTest
@testable import JarvisCallBridge

/// Phase 3 §31 items 1-3: product default is Work Mode ON / Auto Answer ON at launch, and that
/// startup alone (no verified Active call yet) never touches audio.
@MainActor
final class BridgeViewModelPhase3Tests: XCTestCase {
    func testStartArmsWorkModeAndAutoAnswerByDefaultWithoutTouchingAudio() {
        let scanner = MockAccessibilityScanning()
        let spies = CallAudioTestFixtures.makeSpies()
        let session = CallAudioSessionController(routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store, pcmController: spies.pcm, processMute: spies.mute, logger: BridgeLogger())
        let model = BridgeViewModel(accessibilityScanner: scanner, callAudioSession: session)

        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }

        XCTAssertTrue(model.stateMachine.workModeEnabled, "§3: Work Mode must default to ON at launch")
        XCTAssertEqual(model.stateMachine.state, .armed)
        XCTAssertTrue(model.autoAnswer.isEnabled, "§3: Auto Answer must default to ON at launch")

        XCTAssertTrue(spies.activator.captureActiveCalls.isEmpty, "startup / Work Mode ON must never seize audio before a real call")
        XCTAssertTrue(spies.activator.injectActiveCalls.isEmpty)
        XCTAssertTrue(spies.route.setOutputCalls.isEmpty)
        XCTAssertTrue(spies.route.setInputCalls.isEmpty)
    }

    /// §21: startup recovery runs before Work Mode auto-arms — verified here by pre-seeding a
    /// recovery record pointing at the Jarvis devices and confirming it's gone (recovered) by the
    /// time `start()` returns, with Work Mode still ending up armed afterward.
    func testStartupRecoveryRunsBeforeWorkModeAutoArms() {
        let scanner = MockAccessibilityScanning()
        let spies = CallAudioTestFixtures.makeSpies()
        spies.store.storedRecord = CallAudioRecoveryRecord(
            version: 1, callSessionID: "stale-session", createdAt: Date(),
            originalInputUID: CallAudioTestFixtures.originalInputUID, originalOutputUID: CallAudioTestFixtures.originalOutputUID, originalSystemOutputUID: CallAudioTestFixtures.originalSystemOutputUID,
            targetInputUID: JarvisAudioDeviceUIDs.inject, targetOutputUID: JarvisAudioDeviceUIDs.capture
        )
        spies.route.currentSnapshot = CallAudioRouteSnapshot(inputUID: JarvisAudioDeviceUIDs.inject, outputUID: JarvisAudioDeviceUIDs.capture, systemOutputUID: CallAudioTestFixtures.originalSystemOutputUID)
        let session = CallAudioSessionController(routeController: spies.route, deviceActivator: spies.activator, recoveryStore: spies.store, pcmController: spies.pcm, processMute: spies.mute, logger: BridgeLogger())
        let model = BridgeViewModel(accessibilityScanner: scanner, callAudioSession: session)

        model.start()
        model.incomingCallObserver.stop()
        defer { model.audioDriver.stop() }

        XCTAssertNil(spies.store.storedRecord, "stale recovery record must be consumed during startup")
        XCTAssertEqual(spies.route.currentSnapshot?.outputUID, CallAudioTestFixtures.originalOutputUID, "original routes must be restored during startup recovery")
        XCTAssertTrue(model.stateMachine.workModeEnabled, "Work Mode still ends up armed after recovery completes")
    }
}
