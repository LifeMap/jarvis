import Foundation

/// CHECKPOINT 2 diagnostic fix. The filtered `Dump Incoming AX Snapshot` found 0 elements during a
/// real incoming call — before touching `AnswerCandidateResolver`'s scoring (PRD instructs:
/// discover the real AX structure first, don't guess), this file adds an unfiltered, bounded raw
/// discovery pass that never applies call-semantic keyword filtering at all.
///
/// Diagnostic Fix #2: the 2nd real-device retest showed that walking from each process's
/// `AXApplication` root pulls in whole unrelated app trees (menu bars, browser tabs, chat history)
/// and exhausts a shared global node budget on whichever process happens to enumerate first. This
/// walk is now always invoked per-**window** (`SystemAccessibilityClient` passes an `AXWindow`
/// element as `root`, never the application root), and explicitly refuses to recurse into
/// `AXMenuBar`/`AXMenuBarItem`/`AXMenu`/`AXMenuItem` subtrees — both a privacy-minimization measure
/// (menu contents aren't call UI) and what keeps a single window from ballooning past its own
/// budget. This exclusion is also what makes ordinary Quit/Close/Edit/recent-item menu commands
/// structurally unable to ever reach `AnswerCandidateResolver`/`CallStateEvidence` extraction — see
/// CHECKPOINT 2's false-positive fix in `SystemAccessibilityClient`.
///
/// The bounded-walk algorithm (`AXRawDiscovery.walk`) is deliberately pure and abstracted over
/// `AXRawNode` so it can be unit tested with a fake tree — no real Accessibility framework call
/// anywhere in the algorithm itself. `SystemAccessibilityClient` supplies the real
/// `AXUIElement`-backed conformer.

/// One ancestor's structural identity (role/subrole/identifier) — deliberately not a live
/// `AXUIElement` reference, so ancestry can be carried into pure value types like
/// `AXElementSnapshot` without leaking the real Accessibility framework into model logic
/// (CHECKPOINT 3 §5).
struct AXAncestorDescriptor: Equatable {
    let role: String?
    let subrole: String?
    let axIdentifier: String?
}

struct AXRawDiscoveryElement {
    let depth: Int
    let pid: pid_t
    let processName: String
    let bundleIdentifier: String?
    let windowIndex: Int
    let role: String?
    let subrole: String?
    let axIdentifier: String?
    let title: String?
    let elementDescription: String?
    let value: String?
    let enabled: Bool
    let actions: [String]
    let childCount: Int
    /// Nearest-first chain of this element's ancestors up to (and including) the window root the
    /// walk started from — CHECKPOINT 3's evidence-locked Answer matching needs to prove an
    /// element sits inside a specific `AXNotificationCenterBanner`/`FACETIME_NOTIFICATION`
    /// ancestor, not just that it exists somewhere in the window.
    let ancestorChain: [AXAncestorDescriptor]

    init(
        depth: Int, pid: pid_t, processName: String, bundleIdentifier: String?, windowIndex: Int,
        role: String?, subrole: String?, axIdentifier: String?, title: String?, elementDescription: String?,
        value: String?, enabled: Bool, actions: [String], childCount: Int,
        ancestorChain: [AXAncestorDescriptor] = []
    ) {
        self.depth = depth
        self.pid = pid
        self.processName = processName
        self.bundleIdentifier = bundleIdentifier
        self.windowIndex = windowIndex
        self.role = role
        self.subrole = subrole
        self.axIdentifier = axIdentifier
        self.title = title
        self.elementDescription = elementDescription
        self.value = value
        self.enabled = enabled
        self.actions = actions
        self.childCount = childCount
        self.ancestorChain = ancestorChain
    }
}

struct AXProcessSummary {
    let pid: pid_t
    let processName: String
    let bundleIdentifier: String?
    let activationPolicy: String
    let windowCount: Int
    let focusedWindowTitle: String?
    let axReadable: Bool
}

/// Abstraction over one AX node's attributes, so the bounded-walk algorithm below never touches
/// the real Accessibility framework directly — this is what makes it unit-testable.
protocol AXRawNode {
    var role: String? { get }
    var subrole: String? { get }
    var axIdentifier: String? { get }
    var title: String? { get }
    var elementDescription: String? { get }
    var value: String? { get }
    var enabled: Bool { get }
    var actions: [String] { get }
    var children: [AXRawNode] { get }
}

/// Result of one bounded window walk. A plain struct rather than a tuple so adding fields (like
/// `excludedMenuNodeCount` in Diagnostic Fix #2) doesn't force every call site to re-destructure.
struct AXWalkOutcome {
    let elements: [AXRawDiscoveryElement]
    let truncated: Bool
    let excludedMenuNodeCount: Int
}

enum AXRawDiscovery {
    /// Roles this walk refuses to recurse into. Menu content is (a) not part of any call UI and
    /// (b) can contain arbitrary app/browser history — recursing into it would defeat the privacy
    /// minimization this diagnostic is supposed to have. The node itself is not recorded either;
    /// only an aggregate `excludedMenuNodeCount` tracks that something was skipped, so truncation
    /// stays visible without dumping menu contents.
    private static let excludedMenuRoles: Set<String> = ["AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem"]

    /// Bounded depth-first walk over a single root (in practice: one window). Deliberately applies
    /// **no** call-semantic filtering — every non-excluded node encountered within bounds is
    /// recorded, regardless of role/title/keywords (PRD's explicit instruction: raw discovery must
    /// not require words like "Answer"/"받기"/"Call").
    static func walk(
        _ root: AXRawNode,
        pid: pid_t,
        processName: String,
        bundleIdentifier: String?,
        windowIndex: Int = 0,
        maxDepth: Int,
        maxNodesForProcess: Int
    ) -> AXWalkOutcome {
        var elements: [AXRawDiscoveryElement] = []
        var visited = 0
        var truncated = false
        var excludedMenuNodeCount = 0

        func recurse(_ node: AXRawNode, depth: Int, ancestors: [AXAncestorDescriptor]) {
            if let role = node.role, excludedMenuRoles.contains(role) {
                excludedMenuNodeCount += 1
                return
            }
            guard visited < maxNodesForProcess else {
                truncated = true
                return
            }
            guard depth <= maxDepth else {
                truncated = true
                return
            }
            visited += 1
            elements.append(AXRawDiscoveryElement(
                depth: depth, pid: pid, processName: processName, bundleIdentifier: bundleIdentifier,
                windowIndex: windowIndex, role: node.role, subrole: node.subrole, axIdentifier: node.axIdentifier,
                title: AXRedaction.redact(node.title), elementDescription: AXRedaction.redact(node.elementDescription),
                value: AXRedaction.redact(node.value), enabled: node.enabled, actions: node.actions,
                childCount: node.children.count, ancestorChain: ancestors
            ))
            let childAncestors = [AXAncestorDescriptor(role: node.role, subrole: node.subrole, axIdentifier: node.axIdentifier)] + ancestors
            for child in node.children {
                if visited >= maxNodesForProcess { truncated = true; return }
                recurse(child, depth: depth + 1, ancestors: childAncestors)
            }
        }

        recurse(root, depth: 0, ancestors: [])
        return AXWalkOutcome(elements: elements, truncated: truncated, excludedMenuNodeCount: excludedMenuNodeCount)
    }
}

/// PRD §22 / this checkpoint's instructions: redact obviously-sensitive long text (caller names,
/// phone numbers) from diagnostic logs rather than dumping them verbatim. Structural strings
/// (role names, short button titles) pass through unchanged since they're what diagnosis needs.
enum AXRedaction {
    static func redact(_ text: String?, maxLength: Int = 40) -> String? {
        guard let text, !text.isEmpty else { return text }
        let digitCount = text.filter(\.isNumber).count
        if digitCount >= 7 {
            return "<redacted: digit-heavy value, len=\(text.count)>"
        }
        if text.count > maxLength {
            let prefix = String(text.prefix(maxLength))
            return "\(prefix)…<truncated, len=\(text.count)>"
        }
        return text
    }
}
