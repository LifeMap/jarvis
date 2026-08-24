import XCTest
@testable import JarvisCallBridge

final class CallTelURLTests: XCTestCase {
    func testBuildsTelFromStoredNumber() {
        XCTAssertEqual(CallTelURL.make(phoneNumber: "+821011122233")?.absoluteString, "tel:+821011122233")
    }

    func testRejectsUnknown() {
        XCTAssertNil(CallTelURL.make(phoneNumber: "unknown"))
        XCTAssertNil(CallTelURL.make(phoneNumber: ""))
    }
}
