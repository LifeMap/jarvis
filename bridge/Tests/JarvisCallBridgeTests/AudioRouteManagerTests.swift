import XCTest
@testable import JarvisCallBridge

final class AudioRouteManagerTests: XCTestCase {
    /// Reads the real system route twice in a row with nothing in between that could plausibly
    /// change it. Confirms the reader is non-mutating by construction: two back-to-back reads of
    /// unchanged system state must be identical (PRD §11 "snapshot before / snapshot after").
    func testConsecutiveSnapshotsAreIdentical() throws {
        let reader = CoreAudioRouteReader()
        guard let before = reader.currentSnapshot(), let after = reader.currentSnapshot() else {
            throw XCTSkip("No CoreAudio device access in this environment")
        }
        XCTAssertEqual(before, after)
    }

    func testFakeReaderRoundTrips() {
        let fake = FakeAudioRouteReader(snapshot: AudioRouteSnapshot(
            defaultInputDeviceID: 1,
            defaultOutputDeviceID: 2,
            defaultSystemOutputDeviceID: 2,
            defaultInputName: "Test Mic",
            defaultOutputName: "Test Speakers",
            defaultSystemOutputName: "Test Speakers"
        ))
        XCTAssertEqual(fake.currentSnapshot()?.defaultInputName, "Test Mic")
    }
}

/// A `class` (not `struct`) with a mutable `snapshot` — Phase 3 UI-sync tests need to change what
/// the "real CoreAudio route" reports mid-test (simulating a takeover/restore actually having
/// happened) and assert `BridgeViewModel.routeSnapshot` picks up the new value automatically.
final class FakeAudioRouteReader: AudioRouteReading {
    var snapshot: AudioRouteSnapshot?
    init(snapshot: AudioRouteSnapshot?) { self.snapshot = snapshot }
    func currentSnapshot() -> AudioRouteSnapshot? { snapshot }
}
