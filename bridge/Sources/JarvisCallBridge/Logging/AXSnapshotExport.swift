import Foundation

/// CHECKPOINT 2 Diagnostic Fix #2 helper — the raw AX snapshot filename convention, kept separate
/// from `LogExport`'s filenames so "Copy/Save Raw AX Snapshot" and "Copy All Logs"/"Save Logs…"
/// are never mixed up in a Downloads folder. Pure/testable, same pattern as `LogExport`.
enum AXSnapshotExport {
    static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        return "jarvis-ax-snapshot-\(formatter.string(from: date)).txt"
    }

    /// CHECKPOINT 2 Focused Call AX Snapshot filename — distinct prefix from the full raw
    /// snapshot above, so the two diagnostics never collide in a Downloads folder.
    static func focusedCallFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        return "jarvis-call-ax-snapshot-\(formatter.string(from: date)).txt"
    }
}
