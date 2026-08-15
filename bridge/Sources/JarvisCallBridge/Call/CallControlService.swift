import Foundation

/// Placeholder interface for CB v2 Phase 2's Accessibility-driven auto-answer. Declared now so
/// later phases have a stable seam to implement against, but deliberately has no `answer()` (or
/// any other action-performing) requirement — Phase 0 must not click anything (PRD §9, §10).
protocol CallControlService {
    var accessibilityGranted: Bool { get }
}
