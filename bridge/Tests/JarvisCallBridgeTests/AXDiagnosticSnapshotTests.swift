import XCTest
@testable import JarvisCallBridge

/// Diagnostic Fix #2: proves the dedicated snapshot type is genuinely independent of
/// `BridgeLogger`'s 500-line retention cap, and that its rendered text (what "Copy/Save Raw AX
/// Snapshot" actually export) contains the complete data, not a truncated/summarized view.
final class AXDiagnosticSnapshotTests: XCTestCase {
    private func makeElement(index: Int, windowIndex: Int) -> AXRawDiscoveryElement {
        AXRawDiscoveryElement(
            depth: 0, pid: 1, processName: "Fake", bundleIdentifier: nil, windowIndex: windowIndex,
            role: "AXButton", subrole: nil, axIdentifier: nil, title: "element-\(index)",
            elementDescription: nil, value: nil, enabled: true, actions: [], childCount: 0
        )
    }

    func testRenderTextIncludesEveryElementRegardlessOfCountExceedingLoggerCap() {
        // BridgeLogger caps at 500 lines total. A snapshot with 600 elements alone must still
        // render every one of them — this is what makes it "not limited by BridgeLogger's cap."
        let elements = (0..<600).map { makeElement(index: $0, windowIndex: 0) }
        let snapshot = AXDiagnosticSnapshot(
            generatedAt: Date(), trusted: true, processInventory: [], windows: [], elements: elements,
            excludedMenuNodeCount: 0, totalNodeCount: elements.count, totalNodeCap: 5000, totalNodeCapHit: false
        )

        let text = snapshot.renderText()
        for index in [0, 250, 599] {
            XCTAssertTrue(text.contains("element-\(index)"), "element-\(index) must be present in the full export")
        }
        XCTAssertGreaterThan(text.components(separatedBy: "\n").count, 600)
    }

    func testRenderTextIncludesProcessWindowAndElementSections() {
        let process = AXProcessSummary(pid: 1, processName: "Fake", bundleIdentifier: "com.example.fake", activationPolicy: "regular", windowCount: 1, focusedWindowTitle: "Window", axReadable: true)
        let window = AXWindowSummary(pid: 1, processName: "Fake", bundleIdentifier: "com.example.fake", windowIndex: 0, windowTitle: "Window", nodeCount: 1, truncated: false)
        let snapshot = AXDiagnosticSnapshot(
            generatedAt: Date(), trusted: true, processInventory: [process], windows: [window], elements: [makeElement(index: 0, windowIndex: 0)],
            excludedMenuNodeCount: 2, totalNodeCount: 1, totalNodeCap: 5000, totalNodeCapHit: false
        )

        let text = snapshot.renderText()
        XCTAssertTrue(text.contains("[AX-PROCESS]"))
        XCTAssertTrue(text.contains("[AX-WINDOW]"))
        XCTAssertTrue(text.contains("[AX-RAW]"))
        XCTAssertTrue(text.contains("excludedMenuNodeCount=2"))
    }

    func testEmptySnapshotIsUntrustedAndHasNoData() {
        let snapshot = AXDiagnosticSnapshot.empty(trusted: false)
        XCTAssertFalse(snapshot.trusted)
        XCTAssertTrue(snapshot.processInventory.isEmpty)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertTrue(snapshot.elements.isEmpty)
    }

    func testDefaultFileNameFormatIsDistinctFromLogExport() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 15
        components.hour = 14
        components.minute = 8
        components.second = 39
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: components)!

        let name = AXSnapshotExport.defaultFileName(date: date)
        XCTAssertEqual(name, "jarvis-ax-snapshot-20260815-140839.txt")
        XCTAssertNotEqual(name, LogExport.defaultFileName(date: date), "raw AX snapshots and normal logs must never share a filename convention")
    }
}
