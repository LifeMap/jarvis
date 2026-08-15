import XCTest
@testable import JarvisCallBridge

@MainActor
final class CallLifecycleTrackerTests: XCTestCase {
    /// Controllable clock so debounce tests never need to actually sleep.
    final class FakeClock {
        var now = Date()
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    func testIdleToRingingOnCandidateDiscovery() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        XCTAssertEqual(tracker.state, .idle)
        tracker.update(hasAnyCandidate: true, evidence: .none)
        XCTAssertEqual(tracker.state, .ringing)
        XCTAssertNotNil(tracker.currentSession)
    }

    /// PRD §14: repeated detections of the same ringing call must not create multiple sessions.
    func testDuplicateIncomingDetectionsKeepSameSession() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        let firstSessionID = tracker.currentSession?.id
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.update(hasAnyCandidate: true, evidence: .none)
        XCTAssertEqual(tracker.currentSession?.id, firstSessionID)
    }

    /// CHECKPOINT 3 Ringing → Active Transition Grace Fix: real-device evidence showed candidate
    /// disappearance does NOT immediately mean the caller hung up — macOS's native answer-UI
    /// transition itself briefly shows neither the ringing nor the active signature. This is now
    /// a bounded grace (`answerTransitionGrace`), not an immediate drop to Idle — see
    /// `AnswerTransitionGraceTests` for the full grace-window behavior.
    func testRingingWithoutActiveEvidenceEventuallyReturnsToIdleAfterGraceExpires() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(answerTransitionGrace: 2.5, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        XCTAssertEqual(tracker.state, .ringing)

        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertEqual(tracker.state, .answering, "must not drop straight to idle — enters the bounded answer-transition grace first")

        clock.advance(2.6)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertEqual(tracker.state, .idle, "no evidence ever appeared within the grace window — caller genuinely hung up")
    }

    /// "manual answer" path: nobody called markAnswering(), evidence alone drives ringing→active.
    func testManualAnswerEvidenceTransitionsRingingToActive() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        XCTAssertEqual(tracker.state, .active)
    }

    /// "auto answer" path: markAnswering() moves to .answering, then evidence confirms .active.
    func testAutoAnswerPathGoesThroughAnsweringToActive() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.markAnswering()
        XCTAssertEqual(tracker.state, .answering)
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        XCTAssertEqual(tracker.state, .active)
    }

    func testCallEndEvidenceTransitionsActiveToIdleAfterDebounce() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(endDebounceInterval: 1.0, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        XCTAssertEqual(tracker.state, .active)

        tracker.update(hasAnyCandidate: false, evidence: .none) // evidence disappears
        XCTAssertEqual(tracker.state, .ending)

        clock.advance(1.5)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertEqual(tracker.state, .idle)
    }

    /// PRD §20: a momentary AX refresh must not be mistaken for the call ending.
    func testTemporaryEvidenceDisappearanceDuringDebounceDoesNotEndCall() {
        let clock = FakeClock()
        let tracker = CallLifecycleTracker(endDebounceInterval: 1.0, logger: BridgeLogger(), now: { clock.now })
        tracker.update(hasAnyCandidate: true, evidence: .none)
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        XCTAssertEqual(tracker.state, .active)

        tracker.update(hasAnyCandidate: false, evidence: .none) // blip
        XCTAssertEqual(tracker.state, .ending)

        clock.advance(0.2) // still well inside the debounce window
        tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence) // evidence returns
        XCTAssertEqual(tracker.state, .active, "must recover to active, not finalize as ended")
    }

    func testUnknownStateDoesNotAutoTransition() {
        let tracker = CallLifecycleTracker(logger: BridgeLogger())
        tracker.markUnknown(reason: "test")
        XCTAssertEqual(tracker.state, .unknown)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        XCTAssertEqual(tracker.state, .unknown, "unknown must not silently resolve itself via update()")
    }
}
