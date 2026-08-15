import Foundation

/// CHECKPOINT 2 — Focused Call AX Differential Diagnostics. The full Raw AX Discovery Snapshot
/// (Diagnostic Fix #2) is thorough but slow — ~98s scanning 169 processes/23 windows/5186 nodes on
/// the real device — far too slow to capture a transient ~20-30s incoming-ringing UI before it
/// disappears. This is a separate, narrowly-scoped, fast diagnostic: only known call-related Apple
/// processes, window-only (same structural lesson as Diagnostic Fix #2 — never the `AXApplication`
/// root), menu roles excluded. It exists purely to *capture real evidence* of the incoming-call
/// UI's actual AX structure — nothing here feeds `AnswerCandidateResolver`/`CallLifecycleTracker`.

struct FocusedCallProcessSummary {
    let pid: pid_t
    let processName: String
    let bundleIdentifier: String?
    let axReadable: Bool
    let windowCount: Int
    let focusedWindowTitle: String?
}

struct FocusedCallWindowSummary {
    let pid: pid_t
    let processName: String
    let bundleIdentifier: String?
    let windowIndex: Int
    let role: String?
    let subrole: String?
    let title: String?
    let identifier: String?
    let elementDescription: String?
    let nodeCount: Int
    let truncated: Bool
}

struct FocusedCallAXSnapshot {
    let generatedAt: Date
    /// User-selected diagnostic metadata only (e.g. "baseline"/"ringing"/"active"/"ended") — never
    /// read by any scanning/resolver logic, purely a label for the human comparing exports.
    let label: String?
    let trusted: Bool
    let processes: [FocusedCallProcessSummary]
    let windows: [FocusedCallWindowSummary]
    let elements: [AXRawDiscoveryElement]
    let excludedMenuNodeCount: Int
    let totalNodeCount: Int
    /// Diagnostic-only hint: was a `com.apple.mobilephone` `AXButton` with description "통신 오디오"
    /// observed. Correlated with a real incoming call in one manual capture; semantics unproven.
    /// **Never** treated as an Answer button, never pressed, never used for state transitions —
    /// purely informational for whoever is reading the export.
    let callPresenceHint: Bool
    let elapsedMs: Int
    let truncated: Bool

    static func empty(trusted: Bool, label: String?, elapsedMs: Int, generatedAt: Date = Date()) -> FocusedCallAXSnapshot {
        FocusedCallAXSnapshot(
            generatedAt: generatedAt, label: label, trusted: trusted, processes: [], windows: [], elements: [],
            excludedMenuNodeCount: 0, totalNodeCount: 0, callPresenceHint: false, elapsedMs: elapsedMs, truncated: false
        )
    }

    var summaryLine: String {
        "processes=\(processes.count) windows=\(windows.count) nodes=\(totalNodeCount) elapsedMs=\(elapsedMs) truncated=\(truncated) callPresenceHint=\(callPresenceHint)"
    }

    /// Full plain-text rendering for "Copy/Save Focused Call AX Snapshot" — independent of
    /// `BridgeLogger`'s 500-line cap, same rationale as `AXDiagnosticSnapshot.renderText()`.
    func renderText() -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("Jarvis Call Bridge — Focused Call AX Snapshot")
        lines.append("generatedAt=\(formatter.string(from: generatedAt)) label=\(label ?? "-") trusted=\(trusted) elapsedMs=\(elapsedMs) callPresenceHint=\(callPresenceHint)")
        lines.append("")
        lines.append("== Target Processes (\(processes.count)) ==")
        for process in processes {
            lines.append("[AX-CALL-PROCESS] pid=\(process.pid) name=\(process.processName) bundle=\(process.bundleIdentifier ?? "-") axReadable=\(process.axReadable) windows=\(process.windowCount) focusedWindow=\(process.focusedWindowTitle ?? "-")")
        }
        lines.append("")
        lines.append("== Windows (\(windows.count)) ==")
        for window in windows {
            lines.append("[AX-CALL-WINDOW] pid=\(window.pid) proc=\(window.processName) window[\(window.windowIndex)] role=\(window.role ?? "?") subrole=\(window.subrole ?? "-") identifier=\(window.identifier ?? "-") title=\"\(window.title ?? "")\" description=\"\(window.elementDescription ?? "")\" nodes=\(window.nodeCount) truncated=\(window.truncated)")
        }
        lines.append("")
        lines.append("== Elements (\(elements.count)) ==")
        for element in elements {
            lines.append("[AX-CALL-RAW] pid=\(element.pid) proc=\(element.processName) window[\(element.windowIndex)] depth=\(element.depth) role=\(element.role ?? "?") subrole=\(element.subrole ?? "-") identifier=\(element.axIdentifier ?? "-") title=\"\(element.title ?? "")\" description=\"\(element.elementDescription ?? "")\" value=\"\(element.value ?? "")\" enabled=\(element.enabled) actions=\(element.actions) childCount=\(element.childCount)")
        }
        lines.append("")
        lines.append("== Summary ==")
        lines.append("excludedMenuNodeCount=\(excludedMenuNodeCount) totalNodeCount=\(totalNodeCount) elapsedMs=\(elapsedMs) truncated=\(truncated) callPresenceHint=\(callPresenceHint)")
        return lines.joined(separator: "\n")
    }
}
