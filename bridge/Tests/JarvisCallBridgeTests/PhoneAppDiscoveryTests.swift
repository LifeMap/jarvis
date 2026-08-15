import XCTest
@testable import JarvisCallBridge

final class PhoneAppDiscoveryTests: XCTestCase {
    func testBundleIdentifierMatchesPRD() {
        // docs/Jarvis_Call_Bridge_Client_PRD.md fixes this as the CB v2 identification anchor.
        XCTAssertEqual(PhoneAppDiscovery.bundleIdentifier, "com.apple.mobilephone")
    }
}
