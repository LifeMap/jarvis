import Foundation

/// Separate from `AccessibilityScanning` on purpose: call-lifecycle logic (resolver/tracker/
/// auto-answer) only ever talks to `AccessibilityScanning`, and this checkpoint's instructions are
/// explicit that `AnswerCandidateResolver` must not be touched based on guesses — so these
/// diagnostic-only capabilities live on a separate protocol that only the concrete
/// `SystemAccessibilityClient` implements. `BridgeViewModel` exposes this as an optional
/// (nil in any test wiring that injects a mock `AccessibilityScanning`).
protocol AccessibilityRawDiagnosticsProviding {
    /// One-shot, bounded, read-only, window-scoped. See
    /// `SystemAccessibilityClient.performRawDiscovery` for the safety/bounding rationale.
    /// `maxNodesPerWindow` is an independent budget per window — one large window can never
    /// consume another window's or process's share, unlike the earlier shared-global-budget design.
    func performRawDiscovery(maxDepthPerWindow: Int, maxNodesPerWindow: Int, maxTotalNodes: Int) -> AXDiagnosticSnapshot

    /// One-shot, bounded, read-only, window-scoped — but unlike `performRawDiscovery`, restricted
    /// to a small fixed set of known call-related Apple processes so it stays fast enough to
    /// capture a transient incoming-ringing UI (target <1-2s, vs. the full raw dump's ~98s on a
    /// real device). See `SystemAccessibilityClient.captureFocusedCallAXSnapshot` for the exact
    /// process-scope rule. `label` is diagnostic metadata only (never influences scanning).
    func captureFocusedCallAXSnapshot(label: String?, maxDepthPerWindow: Int, maxNodesPerWindow: Int) -> FocusedCallAXSnapshot

    /// Bounded-duration, read-only AX notification logging against the given processes. Never
    /// performs any action — only observes and reports via `onEvent`. `onStopped` fires exactly
    /// once per `start` call that actually started a session — whether ended by an explicit `stop`
    /// or by the bounded duration elapsing — so callers can track running/stopped UI state without
    /// polling.
    func startEventDiagnostics(processes: [AXProcessSummary], durationSeconds: TimeInterval, onEvent: @escaping (String) -> Void, onStopped: @escaping () -> Void)
    func stopEventDiagnostics()
}
