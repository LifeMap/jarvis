import XCTest
@testable import JarvisCallBridge

@MainActor
final class LogExportTests: XCTestCase {
    func testExportTextJoinsLinesWithNewlinesPreservingOrder() {
        let logger = BridgeLogger()
        logger.log("[BRIDGE] app started")
        logger.log("[AX-AUTH] trusted=true")
        logger.log("[AX-RAW] pid=1 role=AXButton")

        let exported = logger.exportText()
        let lines = exported.components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("[BRIDGE] app started"))
        XCTAssertTrue(lines[1].hasSuffix("[AX-AUTH] trusted=true"))
        XCTAssertTrue(lines[2].hasSuffix("[AX-RAW] pid=1 role=AXButton"))
    }

    func testExportTextIsEmptyStringWhenNoLogsYet() {
        let logger = BridgeLogger()
        XCTAssertEqual(logger.exportText(), "")
    }

    func testDefaultFileNameFormat() {
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

        let name = LogExport.defaultFileName(date: date)
        XCTAssertEqual(name, "jarvis-call-bridge-log-20260815-140839.txt")
    }
}
