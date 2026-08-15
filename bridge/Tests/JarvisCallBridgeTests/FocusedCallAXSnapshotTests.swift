import ApplicationServices
import XCTest
@testable import JarvisCallBridge

/// CHECKPOINT 2 — Focused Call AX Differential Diagnostics tests.
final class FocusedCallAXSnapshotTests: XCTestCase {
    // MARK: - §15: process scope stays narrow

    func testFaceTimeNotificationHelperPrefixMatchIsNarrow() {
        XCTAssertTrue(SystemAccessibilityClient.isFaceTimeNotificationHelper(bundleIdentifier: "com.apple.facetime.NotificationService"))
        XCTAssertTrue(SystemAccessibilityClient.isFaceTimeNotificationHelper(bundleIdentifier: "com.apple.facetime.NotificationViewBridgeService"))
        XCTAssertTrue(SystemAccessibilityClient.isFaceTimeNotificationHelper(bundleIdentifier: "com.apple.FaceTime.FaceTimeNotificationExtension"))
    }

    func testFaceTimeNotificationHelperPrefixMatchExcludesUnrelatedProcesses() {
        XCTAssertFalse(SystemAccessibilityClient.isFaceTimeNotificationHelper(bundleIdentifier: "com.apple.mobilephone"))
        XCTAssertFalse(SystemAccessibilityClient.isFaceTimeNotificationHelper(bundleIdentifier: "com.apple.notificationcenterui"))
        XCTAssertFalse(SystemAccessibilityClient.isFaceTimeNotificationHelper(bundleIdentifier: "com.example.other"))
        XCTAssertFalse(SystemAccessibilityClient.isFaceTimeNotificationHelper(bundleIdentifier: nil))
        XCTAssertFalse(SystemAccessibilityClient.isFaceTimeNotificationHelper(bundleIdentifier: "com.apple.finder"), "must not match unrelated Apple processes just for sharing the com.apple prefix")
    }

    func testPrimaryTargetBundleIdentifiersAreExactlyThePhaseTwoCandidates() {
        XCTAssertEqual(SystemAccessibilityClient.focusedPrimaryBundleIdentifiers, ["com.apple.mobilephone", "com.apple.notificationcenterui"])
    }

    // MARK: - Trust gate (test process is never Accessibility-trusted)

    func testCaptureFocusedCallAXSnapshotWhenNotTrustedReturnsEmptySnapshot() {
        let client = SystemAccessibilityClient()
        let snapshot = client.captureFocusedCallAXSnapshot(label: "baseline", maxDepthPerWindow: 8, maxNodesPerWindow: 300)

        XCTAssertEqual(snapshot.trusted, AXIsProcessTrusted())
        if !snapshot.trusted {
            XCTAssertTrue(snapshot.processes.isEmpty)
            XCTAssertTrue(snapshot.windows.isEmpty)
            XCTAssertTrue(snapshot.elements.isEmpty)
            XCTAssertFalse(snapshot.callPresenceHint)
        }
    }

    func testConformsToRawDiagnosticsProtocolWithFocusedCapture() {
        let client: AccessibilityRawDiagnosticsProviding = SystemAccessibilityClient()
        XCTAssertNotNil(client)
    }

    // MARK: - §18: dedicated snapshot independent of BridgeLogger's 500-line cap

    private func makeElement(index: Int) -> AXRawDiscoveryElement {
        AXRawDiscoveryElement(
            depth: 0, pid: 1, processName: "Fake", bundleIdentifier: nil, windowIndex: 0,
            role: "AXButton", subrole: nil, axIdentifier: nil, title: "element-\(index)",
            elementDescription: nil, value: nil, enabled: true, actions: [], childCount: 0
        )
    }

    func testRenderTextIncludesEveryElementRegardlessOfCountExceedingLoggerCap() {
        let elements = (0..<600).map { makeElement(index: $0) }
        let snapshot = FocusedCallAXSnapshot(
            generatedAt: Date(), label: "ringing", trusted: true, processes: [], windows: [], elements: elements,
            excludedMenuNodeCount: 0, totalNodeCount: elements.count, callPresenceHint: false, elapsedMs: 42, truncated: false
        )

        let text = snapshot.renderText()
        for index in [0, 300, 599] {
            XCTAssertTrue(text.contains("element-\(index)"))
        }
        XCTAssertGreaterThan(text.components(separatedBy: "\n").count, 600)
    }

    func testSummaryLineIncludesElapsedMsAndCallPresenceHint() {
        let snapshot = FocusedCallAXSnapshot.empty(trusted: true, label: "baseline", elapsedMs: 17)
        XCTAssertTrue(snapshot.summaryLine.contains("elapsedMs=17"))
        XCTAssertTrue(snapshot.summaryLine.contains("callPresenceHint=false"))
    }

    /// §17: the focused capture path has no press capability at all — same compile-time
    /// guarantee as the full raw discovery, since it's built on the same `AXRawNode`/
    /// `AXRawDiscovery.walk` machinery (`{ get }`-only protocol, no mutating members).
    func testFocusedCaptureReusesReadOnlyWalkMachinery() {
        // If this compiles, `AXRawDiscovery.walk` (which `captureFocusedCallAXSnapshot` calls
        // internally) has no way to perform an AX action — there is no such member on `AXRawNode`.
        let node = FakeAXNode(role: "AXButton", title: "Answer", actions: ["AXPress"])
        _ = AXRawDiscovery.walk(node, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 1, maxNodesForProcess: 1)
        XCTAssertFalse(node.wasMutated)
    }
}
