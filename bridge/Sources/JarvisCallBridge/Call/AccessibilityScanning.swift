import Foundation

/// A read-only, value-type snapshot of one AX element's relevant attributes. Deliberately not a
/// live `AXUIElement` — keeping the scanning boundary in terms of plain values is what makes
/// `AnswerCandidateResolver`/`AutoAnswerController`/`CallLifecycleTracker` unit-testable with a
/// mock, with no real Accessibility framework calls anywhere in the test target (PRD §29).
struct AXElementSnapshot: Equatable, Identifiable {
    /// Stable-ish identifier for dedup across repeated scans of what is structurally the same
    /// element (PRD §14). Real implementation derives this from AXIdentifier when present, else a
    /// hash of (pid, role, title, description, approximate position).
    let id: String
    let pid: pid_t
    let bundleIdentifier: String?
    let role: String?
    let subrole: String?
    let axIdentifier: String?
    let title: String?
    let elementDescription: String?
    let enabled: Bool
    let actions: [String]
    /// When this scanner first observed this element's `id` — used as "recently appeared"
    /// evidence, not when AX itself created it (AX doesn't expose creation time).
    let firstObservedAt: Date
    /// CHECKPOINT 3: nearest-first chain of this element's ancestors up to and including its
    /// window — immutable structural metadata only (role/subrole/identifier), never a live
    /// `AXUIElement` reference, so it stays safe to carry into pure model logic
    /// (`IncomingAnswerControlMatcher`). Defaults to `[]` for any snapshot that doesn't need it
    /// (every pre-CHECKPOINT-3 test fixture keeps compiling unchanged).
    let ancestorChain: [AXAncestorDescriptor]

    init(
        id: String, pid: pid_t, bundleIdentifier: String?, role: String?, subrole: String?,
        axIdentifier: String?, title: String?, elementDescription: String?, enabled: Bool,
        actions: [String], firstObservedAt: Date, ancestorChain: [AXAncestorDescriptor] = []
    ) {
        self.id = id
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.role = role
        self.subrole = subrole
        self.axIdentifier = axIdentifier
        self.title = title
        self.elementDescription = elementDescription
        self.enabled = enabled
        self.actions = actions
        self.firstObservedAt = firstObservedAt
        self.ancestorChain = ancestorChain
    }

    var supportsPress: Bool { actions.contains("AXPress") }
}

/// Aggregated, higher-level signals `CallLifecycleTracker` uses to decide active/end transitions
/// (PRD §19–20). Each field is an independent yes/no observation; the tracker requires a
/// combination of them before committing to a transition, never a single signal alone.
struct CallStateEvidence: Equatable {
    let answerButtonPresent: Bool
    let endCallButtonPresent: Bool
    let activeCallControlsPresent: Bool
    let callDurationUIPresent: Bool

    static let none = CallStateEvidence(answerButtonPresent: false, endCallButtonPresent: false, activeCallControlsPresent: false, callDurationUIPresent: false)
}

enum AccessibilityPressResult: Equatable {
    case success
    case failed(String)
}

/// The entire boundary between call-lifecycle logic and the real Accessibility framework.
/// Production code talks to `SystemAccessibilityClient`; tests talk to a mock. Nothing in this
/// protocol performs anything beyond reading AX state and, for `press(_:)`, a single
/// `AXUIElementPerformAction(kAXPressAction)` on an element the caller already resolved with high
/// confidence — no coordinate clicking, no CGEvent, no AppleScript (PRD §30).
protocol AccessibilityScanning {
    /// Read-only. Scans currently-relevant call-related UI surfaces at bounded depth and returns
    /// whatever interactive elements were found. Must never click, focus, or move anything.
    func scanCallRelevantElements() -> [AXElementSnapshot]

    /// Derives `CallStateEvidence` for whichever call-related surfaces currently exist (answer
    /// button, end-call button, active-call controls, duration UI). Read-only.
    func currentCallStateEvidence() -> CallStateEvidence

    /// The only place an AX action is ever performed. Callers must have already validated
    /// confidence/state/dedup before calling this.
    func press(_ snapshot: AXElementSnapshot) -> AccessibilityPressResult
}
