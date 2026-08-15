import AppKit
import ApplicationServices
import Foundation

/// Real Accessibility implementation. **Provisional and explicitly unverified**: which process
/// actually hosts the incoming-call UI on macOS 26 (Phone.app itself vs. Notification Center vs.
/// something else) is not known until CHECKPOINT 2's diagnostic dump runs against a real call
/// (PRD §10) — this scans both candidate processes rather than assuming one.
///
/// Read-only except for `press(_:)`, which is the only AX action this type ever performs, and
/// only ever `kAXPressAction` on an element the caller already resolved with high confidence.
final class SystemAccessibilityClient: AccessibilityScanning {
    private static let candidateBundleIdentifiers = [
        "com.apple.mobilephone",
        "com.apple.notificationcenterui"
    ]

    private static let maxScanDepth = 8
    private static let maxNodesPerProcess = 600

    private var firstObservedIDs: [String: Date] = [:]
    private let eventDiagnosticsSession = AXEventDiagnosticsSession()

    func scanCallRelevantElements() -> [AXElementSnapshot] {
        var results: [AXElementSnapshot] = []
        for bundleIdentifier in Self.candidateBundleIdentifiers {
            results.append(contentsOf: scanProcess(bundleIdentifier: bundleIdentifier))
        }
        return results
    }

    /// Delegates entirely to the pure, unit-testable `CallStateEvidenceExtractor` — see that type
    /// for the CHECKPOINT 2 false-positive fix details.
    func currentCallStateEvidence() -> CallStateEvidence {
        CallStateEvidenceExtractor.extract(from: scanCallRelevantElements())
    }

    func press(_ snapshot: AXElementSnapshot) -> AccessibilityPressResult {
        guard AXIsProcessTrusted() else {
            return .failed("Accessibility not trusted")
        }
        let appElement = AXUIElementCreateApplication(snapshot.pid)
        guard let target = findElement(matching: snapshot, in: appElement, depth: 0) else {
            return .failed("element no longer present")
        }
        let status = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard status == .success else {
            return .failed("AXUIElementPerformAction error \(status.rawValue)")
        }
        return .success
    }

    // MARK: - Scanning

    /// CHECKPOINT 2 false-positive fix: previously walked from `AXUIElementCreateApplication`
    /// (the application root), which — exactly like Diagnostic Fix #2's raw-discovery bug — pulls
    /// in the entire menu bar and window chrome tree, not just call-relevant UI. A confirmed
    /// real-device no-call baseline scanned 341 such elements this way. This now reuses
    /// `AXRawDiscovery.walk` window-only, with the same `AXMenuBar`/`AXMenu`/`AXMenuItem`
    /// exclusion Diagnostic Fix #2 already has (and already has test coverage for) — so this
    /// scanner inherits that structural guarantee instead of re-implementing it by hand.
    private func scanProcess(bundleIdentifier: String) -> [AXElementSnapshot] {
        guard AXIsProcessTrusted() else { return [] }
        guard let app = runningApplication(bundleIdentifier: bundleIdentifier) else { return [] }
        return scanWindows(pid: app.processIdentifier, processName: app.localizedName ?? bundleIdentifier, bundleIdentifier: bundleIdentifier)
    }

    /// CHECKPOINT 3 Production/Focused AX Parity Fix: real-device evidence showed the Focused Call
    /// AX Snapshot reliably found the live `FACETIME_NOTIFICATION` banner (windows=5, nodes=88,
    /// stable across repeated captures) while production's `scanCallRelevantElements()` found
    /// nothing at the same moment — even though both ultimately call the identical
    /// `AXRawDiscovery.walk` on the identical window element. The divergence was upstream of the
    /// walk: this used to resolve the target process via
    /// `NSRunningApplication.runningApplications(withBundleIdentifier:)`, while the focused path
    /// (which worked) resolved it via `NSWorkspace.shared.runningApplications` enumeration. The
    /// two are not guaranteed to agree for every process — some system UI agent processes (the
    /// Notification Center banner host among them, per this real-device evidence) can fail to
    /// resolve through the bundle-identifier lookup API while still being visible via `NSWorkspace`
    /// enumeration. Both scan paths now resolve processes through the same mechanism.
    private func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier && $0.processIdentifier > 0 }
    }

    private func scanWindows(pid: pid_t, processName: String, bundleIdentifier: String) -> [AXElementSnapshot] {
        let appElement = AXUIElementCreateApplication(pid)
        guard let windows = Self.attribute(appElement, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else { return [] }

        var results: [AXElementSnapshot] = []
        for (index, window) in windows.enumerated() {
            let outcome = AXRawDiscovery.walk(
                RealAXNode(element: window), pid: pid, processName: processName, bundleIdentifier: bundleIdentifier,
                windowIndex: index, maxDepth: Self.maxScanDepth, maxNodesForProcess: Self.maxNodesPerProcess
            )
            for raw in outcome.elements where raw.actions.contains("AXPress") || raw.role == "AXButton" {
                results.append(snapshot(from: raw, pid: pid, bundleIdentifier: bundleIdentifier))
            }
        }
        return results
    }

    private func snapshot(from raw: AXRawDiscoveryElement, pid: pid_t, bundleIdentifier: String) -> AXElementSnapshot {
        let stableID = raw.axIdentifier ?? "\(pid)|\(raw.role ?? "?")|\(raw.title ?? "")|\(raw.elementDescription ?? "")"
        let firstSeen = firstObservedIDs[stableID] ?? Date()
        firstObservedIDs[stableID] = firstSeen

        return AXElementSnapshot(
            id: stableID,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            role: raw.role,
            subrole: raw.subrole,
            axIdentifier: raw.axIdentifier,
            title: raw.title,
            elementDescription: raw.elementDescription,
            enabled: raw.enabled,
            actions: raw.actions,
            firstObservedAt: firstSeen,
            ancestorChain: raw.ancestorChain
        )
    }

    private func findElement(matching snapshot: AXElementSnapshot, in root: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= Self.maxScanDepth else { return nil }
        let role = Self.attribute(root, kAXRoleAttribute) as? String
        let title = Self.attribute(root, kAXTitleAttribute) as? String
        let description = Self.attribute(root, kAXDescriptionAttribute) as? String
        let axIdentifier = Self.attribute(root, "AXIdentifier") as? String
        let candidateID = axIdentifier ?? "\(snapshot.pid)|\(role ?? "?")|\(title ?? "")|\(description ?? "")"
        if candidateID == snapshot.id {
            return root
        }
        guard let children = Self.attribute(root, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children {
            if let match = findElement(matching: snapshot, in: child, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    // `internal` (not `private`) on purpose — `AXEventDiagnosticsSession` in a different file
    // reuses this same low-level accessor rather than duplicating it.
    static func attribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value
    }

    private static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names = names as? [String] else { return [] }
        return names
    }

    // MARK: - CHECKPOINT 2 diagnostic fix: raw discovery (AccessibilityRawDiagnosticsProviding)

    /// Wraps a real `AXUIElement` to feed the pure, unit-testable `AXRawDiscovery.walk`
    /// algorithm — this is the only place the real Accessibility framework is touched for raw
    /// discovery.
    private struct RealAXNode: AXRawNode {
        let element: AXUIElement

        var role: String? { SystemAccessibilityClient.attribute(element, kAXRoleAttribute) as? String }
        var subrole: String? { SystemAccessibilityClient.attribute(element, kAXSubroleAttribute) as? String }
        var axIdentifier: String? { SystemAccessibilityClient.attribute(element, "AXIdentifier") as? String }
        var title: String? { SystemAccessibilityClient.attribute(element, kAXTitleAttribute) as? String }
        var elementDescription: String? { SystemAccessibilityClient.attribute(element, kAXDescriptionAttribute) as? String }
        var value: String? {
            guard let raw = SystemAccessibilityClient.attribute(element, kAXValueAttribute) else { return nil }
            if let string = raw as? String { return string }
            return "\(raw)"
        }
        var enabled: Bool { (SystemAccessibilityClient.attribute(element, kAXEnabledAttribute) as? Bool) ?? true }
        var actions: [String] { SystemAccessibilityClient.actions(of: element) }
        var children: [AXRawNode] {
            guard let kids = SystemAccessibilityClient.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
            return kids.map { RealAXNode(element: $0) }
        }
    }
}

extension SystemAccessibilityClient: AccessibilityRawDiagnosticsProviding {
    /// One-shot, user-triggered, bounded, read-only. Diagnostic Fix #2 (2nd real-device retest):
    /// walking from each process's `AXApplication` root pulled in whole unrelated app trees
    /// (menu bars, browser tabs, chat history) and a shared global node budget let whichever
    /// process enumerated first exhaust it, starving everything after it. This now does two
    /// separate passes:
    ///
    /// 1. A non-recursive process inventory (public `NSWorkspace` API — no private framework) —
    ///    every running application, one AX call each for window count/focused window title, no
    ///    descent into any element tree at all.
    /// 2. A window-only walk: for every windowed process, every `AXWindow` (never the application
    ///    root — so `AXMenuBar` and everything else outside a window is structurally unreachable)
    ///    gets its own full `maxNodesPerWindow` budget, not a fraction of whatever's left of a
    ///    shared total. The only thing `maxTotalNodes` does is stop scanning *further* windows
    ///    once the aggregate is reached — it never shrinks any individual window's fair share.
    ///
    /// Applies **no** call-semantic filtering — see `AXRawDiscovery.walk`.
    func performRawDiscovery(maxDepthPerWindow: Int, maxNodesPerWindow: Int, maxTotalNodes: Int) -> AXDiagnosticSnapshot {
        let trusted = AXIsProcessTrusted()
        guard trusted else {
            return AXDiagnosticSnapshot.empty(trusted: false)
        }

        var processSummaries: [AXProcessSummary] = []
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }

            let appElement = AXUIElementCreateApplication(pid)
            let windows = Self.attribute(appElement, kAXWindowsAttribute) as? [AXUIElement]
            let axReadable = windows != nil
            let windowCount = windows?.count ?? 0

            var focusedTitle: String?
            if let focusedObj = Self.attribute(appElement, kAXFocusedWindowAttribute) {
                let focused = focusedObj as! AXUIElement
                focusedTitle = AXRedaction.redact(Self.attribute(focused, kAXTitleAttribute) as? String)
            }

            let policy: String
            switch app.activationPolicy {
            case .regular: policy = "regular"
            case .accessory: policy = "accessory"
            case .prohibited: policy = "prohibited"
            @unknown default: policy = "unknown"
            }

            processSummaries.append(AXProcessSummary(
                pid: pid, processName: app.localizedName ?? "?", bundleIdentifier: app.bundleIdentifier,
                activationPolicy: policy, windowCount: windowCount, focusedWindowTitle: focusedTitle, axReadable: axReadable
            ))
        }

        var windowSummaries: [AXWindowSummary] = []
        var elements: [AXRawDiscoveryElement] = []
        var excludedMenuTotal = 0
        var totalVisited = 0
        var capHit = false

        outer: for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            let appElement = AXUIElementCreateApplication(pid)
            guard let windows = Self.attribute(appElement, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else { continue }

            for (index, window) in windows.enumerated() {
                guard totalVisited < maxTotalNodes else {
                    capHit = true
                    break outer
                }
                let windowTitle = AXRedaction.redact(Self.attribute(window, kAXTitleAttribute) as? String)
                let outcome = AXRawDiscovery.walk(
                    RealAXNode(element: window), pid: pid, processName: app.localizedName ?? "?",
                    bundleIdentifier: app.bundleIdentifier, windowIndex: index,
                    maxDepth: maxDepthPerWindow, maxNodesForProcess: maxNodesPerWindow
                )
                elements.append(contentsOf: outcome.elements)
                excludedMenuTotal += outcome.excludedMenuNodeCount
                totalVisited += outcome.elements.count
                windowSummaries.append(AXWindowSummary(
                    pid: pid, processName: app.localizedName ?? "?", bundleIdentifier: app.bundleIdentifier,
                    windowIndex: index, windowTitle: windowTitle, nodeCount: outcome.elements.count, truncated: outcome.truncated
                ))
            }
        }

        return AXDiagnosticSnapshot(
            generatedAt: Date(), trusted: true, processInventory: processSummaries, windows: windowSummaries,
            elements: elements, excludedMenuNodeCount: excludedMenuTotal, totalNodeCount: totalVisited,
            totalNodeCap: maxTotalNodes, totalNodeCapHit: capHit
        )
    }

    /// Focused Call AX Differential Diagnostics: scoped to (1) the two existing candidate
    /// processes (`com.apple.mobilephone`, `com.apple.notificationcenterui`) plus (2) any
    /// currently-running process whose bundle identifier is a FaceTime-notification helper
    /// (matched narrowly by a `com.apple.facetime`/`com.apple.FaceTime` prefix — covers the
    /// observed `com.apple.facetime.NotificationService`,
    /// `com.apple.facetime.NotificationViewBridgeService`,
    /// `com.apple.FaceTime.FaceTimeNotificationExtension` without hardcoding the exact list, and
    /// without requiring any of them to actually be running). Deliberately never falls back to
    /// scanning all running applications — that breadth is exactly what made the full raw
    /// discovery too slow for a transient ringing UI.
    static let focusedPrimaryBundleIdentifiers: Set<String> = candidateBundleIdentifiers.reduce(into: Set<String>()) { $0.insert($1) }

    // `internal` (not `private`) on purpose — unit tested directly (no real AX access needed) to
    // prove the FaceTime-helper match stays narrow and never widens into scanning arbitrary
    // third-party processes.
    static func isFaceTimeNotificationHelper(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let lowered = bundleIdentifier.lowercased()
        return lowered.hasPrefix("com.apple.facetime")
    }

    /// Diagnostic-only correlation hint — see `FocusedCallAXSnapshot.callPresenceHint`'s doc
    /// comment. Exact match on the (already-redacted) description, not a substring, to avoid
    /// false positives from unrelated text that happens to contain this phrase.
    private static let callPresenceHintDescriptions: Set<String> = ["통신 오디오"]

    func captureFocusedCallAXSnapshot(label: String?, maxDepthPerWindow: Int, maxNodesPerWindow: Int) -> FocusedCallAXSnapshot {
        let start = Date()
        guard AXIsProcessTrusted() else {
            return FocusedCallAXSnapshot.empty(trusted: false, label: label, elapsedMs: 0, generatedAt: start)
        }

        let targetApps = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleId = app.bundleIdentifier, app.processIdentifier > 0 else { return false }
            return Self.focusedPrimaryBundleIdentifiers.contains(bundleId) || Self.isFaceTimeNotificationHelper(bundleIdentifier: bundleId)
        }

        var processSummaries: [FocusedCallProcessSummary] = []
        var windowSummaries: [FocusedCallWindowSummary] = []
        var elements: [AXRawDiscoveryElement] = []
        var excludedMenuTotal = 0
        var totalVisited = 0
        var anyTruncated = false

        for app in targetApps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            let windows = Self.attribute(appElement, kAXWindowsAttribute) as? [AXUIElement]
            let axReadable = windows != nil
            let windowCount = windows?.count ?? 0

            var focusedTitle: String?
            if let focusedObj = Self.attribute(appElement, kAXFocusedWindowAttribute) {
                let focused = focusedObj as! AXUIElement
                focusedTitle = AXRedaction.redact(Self.attribute(focused, kAXTitleAttribute) as? String)
            }

            processSummaries.append(FocusedCallProcessSummary(
                pid: pid, processName: app.localizedName ?? "?", bundleIdentifier: app.bundleIdentifier,
                axReadable: axReadable, windowCount: windowCount, focusedWindowTitle: focusedTitle
            ))

            guard let windows, !windows.isEmpty else { continue }
            for (index, window) in windows.enumerated() {
                let role = Self.attribute(window, kAXRoleAttribute) as? String
                let subrole = Self.attribute(window, kAXSubroleAttribute) as? String
                let identifier = Self.attribute(window, "AXIdentifier") as? String
                let title = AXRedaction.redact(Self.attribute(window, kAXTitleAttribute) as? String)
                let description = AXRedaction.redact(Self.attribute(window, kAXDescriptionAttribute) as? String)

                let outcome = AXRawDiscovery.walk(
                    RealAXNode(element: window), pid: pid, processName: app.localizedName ?? "?",
                    bundleIdentifier: app.bundleIdentifier, windowIndex: index,
                    maxDepth: maxDepthPerWindow, maxNodesForProcess: maxNodesPerWindow
                )
                elements.append(contentsOf: outcome.elements)
                excludedMenuTotal += outcome.excludedMenuNodeCount
                totalVisited += outcome.elements.count
                if outcome.truncated { anyTruncated = true }

                windowSummaries.append(FocusedCallWindowSummary(
                    pid: pid, processName: app.localizedName ?? "?", bundleIdentifier: app.bundleIdentifier,
                    windowIndex: index, role: role, subrole: subrole, title: title, identifier: identifier,
                    elementDescription: description, nodeCount: outcome.elements.count, truncated: outcome.truncated
                ))
            }
        }

        let callPresenceHint = elements.contains { element in
            guard let description = element.elementDescription else { return false }
            return Self.callPresenceHintDescriptions.contains(description)
        }
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        return FocusedCallAXSnapshot(
            generatedAt: start, label: label, trusted: true, processes: processSummaries, windows: windowSummaries,
            elements: elements, excludedMenuNodeCount: excludedMenuTotal, totalNodeCount: totalVisited,
            callPresenceHint: callPresenceHint, elapsedMs: elapsedMs, truncated: anyTruncated
        )
    }

    /// Windowed processes from the most recent `performRawDiscovery()` are the natural target
    /// list for event diagnostics (PRD §8) — we don't know which process owns the incoming-call
    /// UI ahead of time, so this reuses whatever raw discovery already found.
    func startEventDiagnostics(processes: [AXProcessSummary], durationSeconds: TimeInterval, onEvent: @escaping (String) -> Void, onStopped: @escaping () -> Void) {
        eventDiagnosticsSession.start(processes: processes, durationSeconds: durationSeconds, onEvent: onEvent, onStopped: onStopped)
    }

    func stopEventDiagnostics() {
        eventDiagnosticsSession.stop()
    }
}
