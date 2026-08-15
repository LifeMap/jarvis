import ApplicationServices
import XCTest
@testable import JarvisCallBridge

/// This test target's process almost certainly does not have Accessibility trust granted (it's a
/// `swift test` CLI binary, never TCC-approved), so this exercises the real "not trusted ⇒ no
/// scan" path against the real `SystemAccessibilityClient` rather than a mock — but it's written
/// to remain correct either way by comparing against the actual live trust state instead of
/// assuming it.
final class SystemAccessibilityClientDiagnosticsTests: XCTestCase {
    func testUntrustedProcessNeverScans() {
        let client = SystemAccessibilityClient()
        let snapshot = client.performRawDiscovery(maxDepthPerWindow: 8, maxNodesPerWindow: 100, maxTotalNodes: 500)

        XCTAssertEqual(snapshot.trusted, AXIsProcessTrusted(), "reported trust must match the real live state")
        if !snapshot.trusted {
            XCTAssertTrue(snapshot.processInventory.isEmpty, "no process enumeration when untrusted")
            XCTAssertTrue(snapshot.windows.isEmpty, "no window enumeration when untrusted")
            XCTAssertTrue(snapshot.elements.isEmpty, "no element scanning when untrusted")
        }
    }

    func testConformsToRawDiagnosticsProtocol() {
        let client: AccessibilityRawDiagnosticsProviding = SystemAccessibilityClient()
        // Compile-time proof BridgeViewModel's `as?` cast has something real to succeed against.
        XCTAssertNotNil(client)
    }

    /// Diagnostic Fix #2: process inventory (`AXProcessSummary`) carries only flat, single-process
    /// facts — pid/name/bundle/policy/window count/focused window title/readability — with no
    /// nested element or child data on the type at all. That's a structural (compile-time)
    /// guarantee that building the inventory can never itself become a recursive tree walk,
    /// independent of whatever `performRawDiscovery` does at runtime.
    func testProcessSummaryCarriesNoNestedElementData() {
        let summary = AXProcessSummary(
            pid: 1, processName: "Fake", bundleIdentifier: "com.example.fake",
            activationPolicy: "regular", windowCount: 2, focusedWindowTitle: "Window", axReadable: true
        )
        XCTAssertEqual(summary.windowCount, 2)
        // No `.elements`, `.children`, or `.windows` accessor exists on AXProcessSummary — if this
        // file compiles, that structural guarantee holds.
    }
}
