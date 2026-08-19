import XCTest
@testable import JarvisCallBridge

/// CHECKPOINT 3 — Ringing → Active Transition Grace Fix. Real-device evidence: after the user
/// manually answers, macOS does not transform the native call banner atomically — there is a real
/// ~1.5s window where neither the verified Ringing signature (응답+거절) nor the verified Active
/// signature (종료+소리끔/키패드) is present. The previous implementation treated that gap as an
/// immediate hangup and closed the session before Active ever appeared. `answerTransitionGrace`
/// (default 2.5s, ~1s of margin over the measured ~1.508s gap) keeps the same session alive through
/// that window. These tests use a controllable clock — never a real sleep.
@MainActor
final class AnswerTransitionGraceTests: XCTestCase {
    final class FakeClock {
        var now = Date()
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    // §16 item 1
    func testRingingSignaturePresentRemainsRinging() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        XCTAssertEqual(tracker.state, .ringing)
        tracker.update(hasAnyCandidate: true, evidence: .none)
        XCTAssertEqual(tracker.state, .ringing)
    }

    // §16 item 2
    func testRingingSignatureDisappearanceStartsGraceInsteadOfIdle() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(answerTransitionGrace: 2.5, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        XCTAssertEqual(tracker.state, .ringing)

        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertEqual(tracker.state, .answering, "must enter the grace state, not drop straight to idle")
    }

    // §16 item 3
    func testSameSessionIdSurvivesGraceIntoActive() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(answerTransitionGrace: 2.5, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        let originalSessionID = tracker.currentSession?.id
        XCTAssertNotNil(originalSessionID)

        tracker.update(hasAnyCandidate: false, evidence: .none)
        clock.advance(1.5)
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)

        XCTAssertEqual(tracker.state, .active)
        XCTAssertEqual(tracker.currentSession?.id, originalSessionID, "answer transition must never generate a new session id")
    }

    // §16 items 4/7
    func testActiveEvidenceAt1_5SecondsTransitionsToActiveImmediately() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(answerTransitionGrace: 2.5, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        clock.advance(1.5)
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        XCTAssertEqual(tracker.state, .active)
    }

    // §16 item 5: reproduces the exact observed real-device timing sequence
    func testExactObservedRealTimingSequenceReachesActiveNeverIdle() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(answerTransitionGrace: 2.5, logger: BridgeLogger(), now: { clock.now })

        // t=0.000  ringing=true active=false
        tracker.update(hasAnyCandidate: true, evidence: .none)
        XCTAssertEqual(tracker.state, .ringing)

        // t≈0.753  ringing=false active=false
        clock.advance(0.753)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertNotEqual(tracker.state, .idle)

        // t≈1.603  ringing=false active=false
        clock.advance(0.850)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertNotEqual(tracker.state, .idle)

        // t≈2.261  ringing=false active=true
        clock.advance(0.658)
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)

        XCTAssertEqual(tracker.state, .active, "must reach Active — never dip through Idle at any point in this sequence")
    }

    // §16 item 6: active evidence cancels the grace before expiry and stays stable afterward
    func testActiveEvidenceCancelsGraceBeforeExpiry() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(answerTransitionGrace: 2.5, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        clock.advance(0.5)
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        XCTAssertEqual(tracker.state, .active)

        clock.advance(5) // well past the original grace deadline
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        XCTAssertEqual(tracker.state, .active, "the cancelled grace timer must have no further effect")
    }

    // §16 items 8/9
    func testNoActiveEvidenceForFullGraceExpiresToIdle() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(answerTransitionGrace: 2.5, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertEqual(tracker.state, .answering)

        clock.advance(2.6)
        tracker.update(hasAnyCandidate: false, evidence: .none)

        XCTAssertEqual(tracker.state, .idle, "caller hung up before answering — must still eventually return to Idle")
        XCTAssertNil(tracker.currentSession)
    }

    // §16 item 10
    func testRingingSignatureReappearanceDuringGraceCancelsPendingEnd() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(answerTransitionGrace: 2.5, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        let sessionID = tracker.currentSession?.id
        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertEqual(tracker.state, .answering)

        clock.advance(1.0)
        tracker.update(hasAnyCandidate: true, evidence: .none) // ringing signature returns

        clock.advance(3.0) // well past the original grace deadline
        tracker.update(hasAnyCandidate: false, evidence: .none)

        XCTAssertNotEqual(tracker.state, .idle, "grace must have been reset when ringing signature reappeared, not left counting down from the original deadline")
        XCTAssertEqual(tracker.currentSession?.id, sessionID, "same session throughout")
    }

    // §16 item 11
    func testDuplicatePollingDoesNotCreateDuplicateSession() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(answerTransitionGrace: 2.5, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        let sessionID = tracker.currentSession?.id

        for _ in 0..<5 {
            tracker.update(hasAnyCandidate: false, evidence: .none)
        }

        XCTAssertEqual(tracker.currentSession?.id, sessionID)
        XCTAssertNotEqual(tracker.state, .idle, "repeated ticks within the grace window must not have expired it early")
    }

    // §16 item 12
    func testGraceExpiryCannotCloseAnAlreadyActiveCall() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(endDebounceInterval: 1.0, answerTransitionGrace: 2.5, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence) // straight to Active, no grace needed
        XCTAssertEqual(tracker.state, .active)

        clock.advance(10) // well past any answerTransitionGrace deadline
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)

        XCTAssertEqual(tracker.state, .active, "an active call must never be affected by the answer-transition grace timer")
    }

    // §16 item 13
    func testOldGraceDeadlineCannotCloseANewerCallSession() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(endDebounceInterval: 1.0, answerTransitionGrace: 2.5, logger: BridgeLogger(), now: { clock.now })

        // First call: rings, nobody answers, grace expires, session closes.
        tracker.update(hasAnyCandidate: true, evidence: .none)
        let firstSessionID = tracker.currentSession?.id
        tracker.update(hasAnyCandidate: false, evidence: .none)
        clock.advance(2.6)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertEqual(tracker.state, .idle)

        // A genuinely new call rings immediately after.
        tracker.update(hasAnyCandidate: true, evidence: .none)
        let secondSessionID = tracker.currentSession?.id
        XCTAssertNotEqual(firstSessionID, secondSessionID)
        XCTAssertEqual(tracker.state, .ringing)

        // `update()` is purely synchronous/poll-driven — no detached Task/timer at all — so there
        // is structurally nothing left over from the first session's grace to affect the second.
        tracker.update(hasAnyCandidate: true, evidence: .none)
        XCTAssertEqual(tracker.state, .ringing)
        XCTAssertEqual(tracker.currentSession?.id, secondSessionID)
    }

    // §16 item 14: Work Mode OFF mid-grace safely resets, via the same `IncomingCallObserver.tick()`
    // path production uses (`workModeArmedProvider() == false` → `tracker.reset()`).
    func testWorkModeOffDuringGraceCancelsPendingTransitionSafely() async {
        let scanner = MockAccessibilityScanning()
        let tracker = CallLifecycleTracker(answerTransitionGrace: 2.5, logger: BridgeLogger())
        let autoAnswer = AutoAnswerController(scanner: scanner, tracker: tracker, logger: BridgeLogger())
        var workModeOn = true
        let observer = IncomingCallObserver(scanner: scanner, tracker: tracker, autoAnswer: autoAnswer, logger: BridgeLogger(), workModeArmedProvider: { workModeOn })

        scanner.snapshotsToReturn = TestSnapshots.ringingCallBannerFixture()
        await observer.tick()
        XCTAssertEqual(tracker.state, .ringing)

        scanner.snapshotsToReturn = [] // banner transforms mid-grace
        await observer.tick()
        XCTAssertEqual(tracker.state, .answering)

        workModeOn = false
        await observer.tick()

        XCTAssertEqual(tracker.state, .idle, "Work Mode OFF must safely reset out of a pending answer transition")
        XCTAssertNil(tracker.currentSession)
    }

    // §16 items 15/16: Bridge disable / Accessibility trust loss (modeled as the scanner returning
    // nothing, matching how `SystemAccessibilityClient` behaves when untrusted) still fails safely
    // to Idle once the grace expires — never stuck, never crashes.
    func testNoEvidenceAtAllDuringGraceEventuallyFailsSafelyToIdle() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(answerTransitionGrace: 2.5, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.update(hasAnyCandidate: false, evidence: .none) // e.g. Accessibility trust lost mid-call
        clock.advance(2.6)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertEqual(tracker.state, .idle)
        XCTAssertNil(tracker.currentSession)
    }
}
