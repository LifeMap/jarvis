import Foundation

/// CHECKPOINT 2 Diagnostic Fix #2. The 2nd real-device retest showed a raw discovery pass can
/// produce far more lines than `BridgeLogger`'s intentional 500-line retention cap can hold —
/// routing that volume through the normal log buffer silently evicted earlier, unrelated log
/// history. This type is a dedicated holder for one discovery pass's complete output, entirely
/// independent of `BridgeLogger`; the logger only ever receives a short summary line about it
/// (see `BridgeViewModel.dumpRawAXDiscovery`), never the per-window/per-element detail.

/// One window found on a windowed process, and how much of it the walk covered. Recorded even for
/// windows that produced zero interesting elements, so "we looked and found nothing" stays
/// distinguishable from "we never looked here."
struct AXWindowSummary {
    let pid: pid_t
    let processName: String
    let bundleIdentifier: String?
    let windowIndex: Int
    let windowTitle: String?
    let nodeCount: Int
    let truncated: Bool
}

struct AXDiagnosticSnapshot {
    let generatedAt: Date
    let trusted: Bool
    let processInventory: [AXProcessSummary]
    let windows: [AXWindowSummary]
    let elements: [AXRawDiscoveryElement]
    let excludedMenuNodeCount: Int
    let totalNodeCount: Int
    let totalNodeCap: Int
    let totalNodeCapHit: Bool

    static func empty(trusted: Bool, generatedAt: Date = Date()) -> AXDiagnosticSnapshot {
        AXDiagnosticSnapshot(
            generatedAt: generatedAt, trusted: trusted, processInventory: [], windows: [], elements: [],
            excludedMenuNodeCount: 0, totalNodeCount: 0, totalNodeCap: 0, totalNodeCapHit: false
        )
    }

    /// Short line safe to hand to `BridgeLogger` — the full detail lives only in `renderText()`.
    var summaryLine: String {
        let anyWindowTruncated = windows.contains { $0.truncated }
        return "processes=\(processInventory.count) windows=\(windows.count) nodes=\(totalNodeCount) excludedMenuNodes=\(excludedMenuNodeCount) truncated=\(totalNodeCapHit || anyWindowTruncated)"
    }

    /// Full plain-text rendering for "Copy Raw AX Snapshot" / "Save Raw AX Snapshot…". Deliberately
    /// independent of `BridgeLogger.exportText()` and its 500-line cap — a large snapshot is never
    /// truncated by log retention, since it never goes through the logger at all.
    func renderText() -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("Jarvis Call Bridge — Raw AX Diagnostic Snapshot")
        lines.append("generatedAt=\(formatter.string(from: generatedAt)) trusted=\(trusted)")
        lines.append("")
        lines.append("== Process Inventory (\(processInventory.count)) ==")
        for process in processInventory {
            lines.append("[AX-PROCESS] pid=\(process.pid) name=\(process.processName) bundle=\(process.bundleIdentifier ?? "-") policy=\(process.activationPolicy) windows=\(process.windowCount) focusedWindow=\(process.focusedWindowTitle ?? "-") axReadable=\(process.axReadable)")
        }
        lines.append("")
        lines.append("== Windows (\(windows.count)) ==")
        for window in windows {
            lines.append("[AX-WINDOW] pid=\(window.pid) proc=\(window.processName) bundle=\(window.bundleIdentifier ?? "-") window[\(window.windowIndex)] title=\"\(window.windowTitle ?? "")\" nodes=\(window.nodeCount) truncated=\(window.truncated)")
        }
        lines.append("")
        lines.append("== Elements (\(elements.count)) ==")
        for element in elements {
            lines.append("[AX-RAW] pid=\(element.pid) proc=\(element.processName) window[\(element.windowIndex)] depth=\(element.depth) role=\(element.role ?? "?") subrole=\(element.subrole ?? "-") identifier=\(element.axIdentifier ?? "-") title=\"\(element.title ?? "")\" description=\"\(element.elementDescription ?? "")\" value=\"\(element.value ?? "")\" enabled=\(element.enabled) actions=\(element.actions) childCount=\(element.childCount)")
        }
        lines.append("")
        lines.append("== Summary ==")
        lines.append("excludedMenuNodeCount=\(excludedMenuNodeCount) totalNodeCount=\(totalNodeCount) totalNodeCap=\(totalNodeCap) totalNodeCapHit=\(totalNodeCapHit)")
        return lines.joined(separator: "\n")
    }
}
