import ApplicationServices
import Combine
import Foundation

/// Read-only Accessibility trust check plus an optional user-initiated prompt. This Phase never
/// calls `AXUIElementPerformAction` or otherwise clicks anything — it only asks macOS to show its
/// own standard permission dialog, exactly like any app requesting a TCC permission (PRD §9).
@MainActor
final class AccessibilityStatus: ObservableObject {
    @Published private(set) var isGranted = false

    private let logger: BridgeLogger

    init(logger: BridgeLogger) {
        self.logger = logger
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        // Explicit [AX-AUTH] line every refresh (not just on change) — CHECKPOINT 2's diagnostic
        // fix instructions want authorization state unambiguous in the log at the moment any
        // scan is attempted, not inferred from an earlier state-change line.
        logger.log("[AX-AUTH] trusted=\(trusted)")
        if trusted != isGranted {
            logger.log("[ACCESSIBILITY] granted=\(trusted)")
        }
        isGranted = trusted
    }

    /// Shows the standard macOS Accessibility permission prompt if not already granted. This is
    /// the only Accessibility API call in Phase 0 beyond the read-only trust check — it never
    /// performs an action on any UI element.
    func requestPermissionPrompt() {
        // Using the documented literal key value rather than the imported
        // `kAXTrustedCheckOptionPrompt` global, which the Swift 6 concurrency checker flags as
        // non-Sendable shared mutable state.
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        logger.log("[ACCESSIBILITY] prompt requested, granted=\(trusted)")
        isGranted = trusted
    }
}
