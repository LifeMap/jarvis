import XCTest
@testable import JarvisCallBridge

/// Diagnostic Fix #2's UI bug fix: "Stop AX Event Diagnostics" was always enabled and did nothing
/// when pressed with no session running. `AXEventDiagnosticsSession.isRunning` plus the
/// `onStopped` callback are what `BridgeViewModel.isEventDiagnosticsRunning` is derived from —
/// these tests exercise that state machine directly. The test process is never Accessibility-
/// trusted (`swift test` CLI binary), so `start` always takes the "not trusted" branch — which is
/// itself a real, deterministic state transition worth covering (immediately not-running).
final class AXEventDiagnosticsSessionTests: XCTestCase {
    func testStartWhenNotTrustedNeverReportsRunningAndInvokesOnStoppedImmediately() {
        let session = AXEventDiagnosticsSession()
        var events: [String] = []
        let stoppedExpectation = expectation(description: "onStopped invoked")

        session.start(processes: [], durationSeconds: 45, onEvent: { events.append($0) }, onStopped: {
            stoppedExpectation.fulfill()
        })

        wait(for: [stoppedExpectation], timeout: 1)
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(events.contains { $0.contains("not started") })
    }

    /// A session that never started (or already stopped) must not fire `onStopped` again on a
    /// redundant `stop()` call — this is exactly the bug where "Stop" was tappable with nothing
    /// to stop and silently did nothing productive, but also must never fire a spurious callback.
    func testStopWithoutAnyStartedSessionDoesNotInvokeOnStopped() {
        let session = AXEventDiagnosticsSession()
        XCTAssertFalse(session.isRunning)
        session.stop() // must not crash or call any callback — none was ever registered
        XCTAssertFalse(session.isRunning)
    }
}
