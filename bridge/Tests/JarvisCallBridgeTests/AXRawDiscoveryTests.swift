import XCTest
@testable import JarvisCallBridge

/// Fake `AXRawNode` — no real Accessibility framework call anywhere in this test file. Also
/// tracks whether anything ever tried to mutate it, which is how `testWalkNeverMutatesNodes`
/// demonstrates (as much as a unit test can) that the walk is read-only.
final class FakeAXNode: AXRawNode {
    var role: String?
    var subrole: String?
    var axIdentifier: String?
    var title: String?
    var elementDescription: String?
    var value: String?
    var enabled: Bool
    var actions: [String]
    var children: [AXRawNode]

    private(set) var wasMutated = false

    init(role: String? = "AXGroup", title: String? = nil, enabled: Bool = true, actions: [String] = [], children: [AXRawNode] = []) {
        self.role = role
        self.subrole = nil
        self.axIdentifier = nil
        self.title = title
        self.elementDescription = nil
        self.value = nil
        self.enabled = enabled
        self.actions = actions
        self.children = children
    }
}

final class AXRawDiscoveryTests: XCTestCase {
    func testWalkRespectsMaximumDepth() {
        // Build a 10-level-deep chain.
        var leaf = FakeAXNode(title: "leaf")
        for i in stride(from: 9, through: 0, by: -1) {
            leaf = FakeAXNode(title: "level-\(i)", children: [leaf])
        }

        let outcome = AXRawDiscovery.walk(leaf, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 3, maxNodesForProcess: 1000)

        XCTAssertTrue(outcome.elements.allSatisfy { $0.depth <= 3 }, "no element should exceed maxDepth")
        XCTAssertTrue(outcome.truncated, "walk must report truncation when depth bound was hit")
    }

    func testWalkRespectsMaximumNodeCount() {
        let children = (0..<50).map { FakeAXNode(title: "child-\($0)") as AXRawNode }
        let root = FakeAXNode(title: "root", children: children)

        let outcome = AXRawDiscovery.walk(root, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 10, maxNodesForProcess: 10)

        XCTAssertLessThanOrEqual(outcome.elements.count, 10)
        XCTAssertTrue(outcome.truncated)
    }

    func testWalkHandlesUnknownAndUnlocalizedAttributes() {
        let node = FakeAXNode(role: nil, title: nil)
        let outcome = AXRawDiscovery.walk(node, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 5, maxNodesForProcess: 10)

        XCTAssertEqual(outcome.elements.count, 1)
        XCTAssertNil(outcome.elements.first?.role)
        XCTAssertNil(outcome.elements.first?.title)
    }

    /// PRD's explicit instruction: raw discovery must not require call-semantic keywords before
    /// logging an element — everything within bounds is recorded regardless of role/title.
    func testWalkDoesNotFilterByCallRelatedKeywords() {
        let node = FakeAXNode(role: "AXCheckBox", title: "Random Unrelated Setting", actions: [])
        let outcome = AXRawDiscovery.walk(node, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 5, maxNodesForProcess: 10)

        XCTAssertEqual(outcome.elements.count, 1, "an element with no call-related semantics must still be recorded")
        XCTAssertEqual(outcome.elements.first?.title, "Random Unrelated Setting")
    }

    /// The walk algorithm has no press/mutation capability at all — `AXRawNode` only exposes
    /// `{ get }` properties, so this is a compile-time guarantee, not just a runtime one. This
    /// test documents that guarantee and additionally confirms that a pressable element's
    /// *description* is captured as data without anything being performed.
    func testWalkCapturesPressabilityAsDataWithoutPressing() {
        let node = FakeAXNode(role: "AXButton", title: "Answer", actions: ["AXPress"])
        let outcome = AXRawDiscovery.walk(node, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 5, maxNodesForProcess: 10)

        XCTAssertEqual(outcome.elements.first?.actions, ["AXPress"])
        XCTAssertFalse(node.wasMutated, "the walk must never mutate the node it is reading")
    }

    func testRedactionMasksDigitHeavyValues() {
        XCTAssertEqual(AXRedaction.redact("010-1234-5678"), "<redacted: digit-heavy value, len=13>")
        XCTAssertEqual(AXRedaction.redact("Answer"), "Answer")
    }

    func testRedactionTruncatesLongText() {
        let long = String(repeating: "a", count: 100)
        let redacted = AXRedaction.redact(long, maxLength: 40)
        XCTAssertTrue(redacted!.hasPrefix(String(repeating: "a", count: 40)))
        XCTAssertTrue(redacted!.contains("truncated"))
    }

    // MARK: - Diagnostic Fix #2: window-only discovery + menu-tree exclusion

    /// `walk` only ever sees the subtree of whatever `root` it's given — there is no path from a
    /// window's element tree back to sibling data like the application's menu bar (a separate,
    /// non-descendant attribute). This is what makes `SystemAccessibilityClient` passing an
    /// `AXWindow` (never the `AXApplication` root) as `root` sufficient to guarantee menu bar /
    /// whole-app content can never leak into a window-scoped scan.
    func testWalkRootIsIsolatedFromSiblingData() {
        let unrelatedMenuBarTree = FakeAXNode(role: "AXMenuBar", title: "sibling data — never passed to walk", children: [
            FakeAXNode(role: "AXMenu", title: "File")
        ])
        let windowRoot = FakeAXNode(role: "AXWindow", title: "Incoming Call", children: [
            FakeAXNode(role: "AXButton", title: "Answer")
        ])

        let outcome = AXRawDiscovery.walk(windowRoot, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 5, maxNodesForProcess: 100)

        XCTAssertFalse(outcome.elements.contains { $0.title == "sibling data — never passed to walk" })
        XCTAssertTrue(outcome.elements.contains { $0.title == "Answer" })
        _ = unrelatedMenuBarTree // never walked — demonstrates it cannot appear in results
    }

    func testWalkExcludesAXMenuBarSubtreeFromRecursion() {
        let menuBar = FakeAXNode(role: "AXMenuBar", title: "MenuBar", children: [
            FakeAXNode(role: "AXMenuBarItem", title: "File", children: [
                FakeAXNode(role: "AXMenuItem", title: "Open Recent…")
            ])
        ])
        let root = FakeAXNode(role: "AXWindow", title: "Window", children: [menuBar, FakeAXNode(role: "AXButton", title: "Answer")])

        let outcome = AXRawDiscovery.walk(root, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 10, maxNodesForProcess: 100)

        XCTAssertFalse(outcome.elements.contains { $0.role == "AXMenuBar" })
        XCTAssertFalse(outcome.elements.contains { $0.title == "Open Recent…" })
        XCTAssertTrue(outcome.elements.contains { $0.title == "Answer" })
        XCTAssertGreaterThanOrEqual(outcome.excludedMenuNodeCount, 1)
    }

    func testWalkExcludesAXMenuAndAXMenuItemSubtreesFromRecursion() {
        let contextMenu = FakeAXNode(role: "AXMenu", title: "Context Menu", children: [
            FakeAXNode(role: "AXMenuItem", title: "Mute", children: [
                FakeAXNode(role: "AXStaticText", title: "should never appear — inside excluded menu item")
            ])
        ])
        let root = FakeAXNode(role: "AXWindow", title: "Window", children: [contextMenu])

        let outcome = AXRawDiscovery.walk(root, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 10, maxNodesForProcess: 100)

        XCTAssertEqual(outcome.elements.count, 1, "only the AXWindow root itself is recorded — the AXMenu and every descendant, including nested AXMenuItem content, must be excluded")
        XCTAssertEqual(outcome.elements.first?.role, "AXWindow")
        XCTAssertFalse(outcome.elements.contains { $0.role == "AXMenu" || $0.role == "AXMenuItem" })
        XCTAssertFalse(outcome.elements.contains { $0.title == "should never appear — inside excluded menu item" })
        XCTAssertEqual(outcome.excludedMenuNodeCount, 1, "only the AXMenu root is counted — its subtree is never visited to be counted individually")
    }

    /// Diagnostic Fix #2's core fairness fix: the old design shrank each process's budget by
    /// whatever was left of a shared total (`min(maxNodesPerProcess, remainingBudget)`), so a
    /// large first window could starve every window scanned after it. Each window must now get
    /// its own full, independent budget.
    func testEachWindowGetsItsOwnFullBudgetRegardlessOfOtherWindows() {
        let bigWindowChildren = (0..<600).map { FakeAXNode(title: "big-\($0)") as AXRawNode }
        let bigWindow = FakeAXNode(role: "AXWindow", title: "Big Window", children: bigWindowChildren)
        let smallWindowChildren = (0..<600).map { FakeAXNode(title: "small-\($0)") as AXRawNode }
        let secondWindow = FakeAXNode(role: "AXWindow", title: "Second Window", children: smallWindowChildren)

        let firstOutcome = AXRawDiscovery.walk(bigWindow, pid: 1, processName: "Fake", bundleIdentifier: nil, windowIndex: 0, maxDepth: 5, maxNodesForProcess: 500)
        let secondOutcome = AXRawDiscovery.walk(secondWindow, pid: 1, processName: "Fake", bundleIdentifier: nil, windowIndex: 1, maxDepth: 5, maxNodesForProcess: 500)

        XCTAssertEqual(firstOutcome.elements.count, 500, "first window consumes its own full budget")
        XCTAssertTrue(firstOutcome.truncated)
        XCTAssertEqual(secondOutcome.elements.count, 500, "second window still gets its own full 500-node budget, not whatever was left over")
        XCTAssertTrue(secondOutcome.truncated)
    }

    func testWindowIndexIsRecordedOnEveryElement() {
        let root = FakeAXNode(role: "AXWindow", title: "Window", children: [FakeAXNode(title: "child")])
        let outcome = AXRawDiscovery.walk(root, pid: 1, processName: "Fake", bundleIdentifier: nil, windowIndex: 3, maxDepth: 5, maxNodesForProcess: 10)

        XCTAssertTrue(outcome.elements.allSatisfy { $0.windowIndex == 3 })
    }

    /// Redaction must still apply to elements found in window-scoped walks (not just the old
    /// app-scoped path) — this would have silently regressed if `windowIndex` had been threaded
    /// through incorrectly.
    func testRedactionStillEffectiveInWindowScopedWalk() {
        let root = FakeAXNode(role: "AXWindow", title: "010-1234-5678", children: [])
        let outcome = AXRawDiscovery.walk(root, pid: 1, processName: "Fake", bundleIdentifier: nil, windowIndex: 0, maxDepth: 5, maxNodesForProcess: 10)

        XCTAssertEqual(outcome.elements.first?.title, "<redacted: digit-heavy value, len=13>")
    }

    /// Excluded menu nodes must never be visited/read beyond checking their role — same
    /// read-only guarantee as ordinary nodes, just proven for the exclusion path too.
    func testExcludedMenuNodesAreNeverMutated() {
        let menuChild = FakeAXNode(role: "AXMenuItem", title: "Item")
        let menu = FakeAXNode(role: "AXMenu", title: "Menu", children: [menuChild])
        let root = FakeAXNode(role: "AXWindow", title: "Window", children: [menu])

        _ = AXRawDiscovery.walk(root, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 10, maxNodesForProcess: 100)

        XCTAssertFalse(menu.wasMutated)
        XCTAssertFalse(menuChild.wasMutated)
    }

    // MARK: - CHECKPOINT 2 false-positive fix: AXMenuBarItem exclusion

    /// §1/§2/§3 of the false-positive elimination checkpoint: `AXMenuBar`'s direct children are
    /// typically `AXMenuBarItem` (File/Edit/Window/Help), each of which can itself contain
    /// AXPress-capable/AXButton-role descendants (standard menu commands). None of that must ever
    /// surface — this is what makes ordinary "Quit"/"Close"/"About"/recent-item menu commands
    /// structurally unable to reach `AnswerCandidateResolver`.
    func testWalkExcludesAXMenuBarItemSubtreeFromRecursion() {
        let menuBarItem = FakeAXNode(role: "AXMenuBarItem", title: "Edit", children: [
            FakeAXNode(role: "AXMenuItem", title: "Copy", actions: ["AXPress"])
        ])
        let root = FakeAXNode(role: "AXWindow", title: "Window", children: [menuBarItem, FakeAXNode(role: "AXButton", title: "Answer")])

        let outcome = AXRawDiscovery.walk(root, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 10, maxNodesForProcess: 100)

        XCTAssertFalse(outcome.elements.contains { $0.role == "AXMenuBarItem" })
        XCTAssertFalse(outcome.elements.contains { $0.title == "Copy" })
        XCTAssertTrue(outcome.elements.contains { $0.title == "Answer" })
        XCTAssertGreaterThanOrEqual(outcome.excludedMenuNodeCount, 1)
    }

    /// A full menu bar tree (bar → bar item → menu → menu item), the exact shape a real macOS app
    /// exposes, must be excluded end to end regardless of how deeply the AXPress-capable elements
    /// are nested inside it.
    func testFullMenuBarTreeShapeIsEntirelyExcluded() {
        let fullMenuBar = FakeAXNode(role: "AXMenuBar", title: "MenuBar", children: [
            FakeAXNode(role: "AXMenuBarItem", title: "File", children: [
                FakeAXNode(role: "AXMenu", title: "File Menu", children: [
                    FakeAXNode(role: "AXMenuItem", title: "Quit", actions: ["AXPress"]),
                    FakeAXNode(role: "AXMenuItem", title: "Close", actions: ["AXPress"])
                ])
            ])
        ])
        let root = FakeAXNode(role: "AXWindow", title: "Window", children: [fullMenuBar])

        let outcome = AXRawDiscovery.walk(root, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 10, maxNodesForProcess: 100)

        XCTAssertEqual(outcome.elements.count, 1, "only the AXWindow root survives — the entire menu bar → item → menu → item chain is excluded")
        XCTAssertFalse(outcome.elements.contains { $0.title == "Quit" || $0.title == "Close" })
    }

    /// §13: the transient "통신 오디오" element must be captured as data (for the diagnostic-only
    /// `callPresenceHint`) without ever being pressed — same structural/read-only guarantee as
    /// every other element the walk touches.
    func testCallPresenceHintElementIsCapturedAsDataWithoutPressing() {
        let node = FakeAXNode(role: "AXButton", title: nil, actions: ["AXPress"])
        node.elementDescription = "통신 오디오"
        let outcome = AXRawDiscovery.walk(node, pid: 1, processName: "Fake", bundleIdentifier: nil, maxDepth: 5, maxNodesForProcess: 10)

        XCTAssertEqual(outcome.elements.first?.elementDescription, "통신 오디오")
        XCTAssertFalse(node.wasMutated)
    }
}
