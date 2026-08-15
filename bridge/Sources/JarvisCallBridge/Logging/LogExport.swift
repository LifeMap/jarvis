import Foundation

/// CHECKPOINT 2 diagnostic UX helper. Pure/testable — no AppKit/NSPasteboard/NSSavePanel calls
/// here, so the filename format can be unit tested without touching the real clipboard or
/// filesystem. The actual pasteboard/save-panel calls live in `ContentView` (AppKit is a UI-layer
/// concern, not a business-logic one).
enum LogExport {
    static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        return "jarvis-call-bridge-log-\(formatter.string(from: date)).txt"
    }
}
