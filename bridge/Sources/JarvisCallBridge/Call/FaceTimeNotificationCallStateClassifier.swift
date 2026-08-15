import Foundation

/// CHECKPOINT 3 Active Call Evidence Fix. Gate A's real-device manual-answer test showed the
/// native call connected successfully, but Jarvis logged "ringing candidate disappeared without
/// active evidence — treating as ended". A focused capture of the genuinely active call banner
/// revealed *why*: `endCallKeywords`/`activeControlKeywords` (CHECKPOINT 2's global keyword
/// matching) don't contain the real active-call labels at all — "종료" was deliberately removed
/// as too generic in CHECKPOINT 2, and "키패드"/"소리 끔" were never call-specific enough to match
/// globally either. The fix is not to restore loose global keywords (that reintroduces the exact
/// false-positive risk CHECKPOINT 2 eliminated — ordinary Phone.app windows also have a keypad,
/// and "종료" appears throughout macOS as a generic Quit/Close word) — it's to recognize these
/// labels as call-state evidence **only** when they're descendants of the same real,
/// evidence-locked `FACETIME_NOTIFICATION` banner `IncomingAnswerControlMatcher` already proved
/// hosts the real Answer control.
///
/// Real-device banner content, differential:
///
///   Ringing:  응답 (enabled) + 거절 (enabled)
///   Active:   종료 (enabled) + at least one of { 소리 끔 (enabled), 키패드 (enabled) }
///
/// "더 보기" appears in both and is never used to distinguish state (§14). "FaceTime 영상 통화"
/// appeared disabled in the one active capture we have and is recorded as diagnostic data only —
/// never required for classification (§13), since its enabled/disabled state may vary.
///
/// Active requires **two independent verified signals** (the end-call control AND at least one
/// in-call control) rather than "종료" alone — critically, "종료" being present and enabled means
/// an active call *has an available end-call control*, not that the call has already ended (§4).
/// Purely read-only: this only classifies already-scanned snapshots, never touches AX itself.
enum FaceTimeNotificationCallState: Equatable {
    case none
    case ringing
    case active
    /// Both the ringing and active signatures matched simultaneously — should not happen in
    /// practice, but per PRD's ambiguity principle this is never silently resolved one way.
    case ambiguous
}

/// CHECKPOINT 3 Production/Focused AX Parity Diagnostic (§5): a funnel breakdown of *why* a scan
/// did or didn't classify, so a real-device investigation doesn't have to guess which structural
/// requirement failed to match. `controlsDetected` is pre-filtered to the known, privacy-safe
/// semantic banner labels (응답/거절/답장/더 보기/종료/소리 끔/키패드/FaceTime 영상 통화) — never
/// arbitrary scanned text (caller names, phone numbers), so it's safe to log directly.
struct FaceTimeNotificationClassificationResult {
    let bannerFound: Bool
    let ownerMatched: Bool
    let systemDialogMatched: Bool
    let notificationBannerMatched: Bool
    let identifierMatched: Bool
    let controlsDetected: [String]
    let ringingSignatureMatched: Bool
    let activeSignatureMatched: Bool
    let state: FaceTimeNotificationCallState
}

enum FaceTimeNotificationCallStateClassifier {
    /// The only banner labels this classifier (or its diagnostics) ever surfaces — deliberately a
    /// closed set of structural/semantic control names, never arbitrary element text.
    private static let knownControlDescriptions: Set<String> = ["응답", "거절", "답장", "더 보기", "종료", "소리 끔", "키패드", "FaceTime 영상 통화"]

    static func classify(from snapshots: [AXElementSnapshot]) -> FaceTimeNotificationCallState {
        classifyWithDiagnostics(from: snapshots).state
    }

    static func classifyWithDiagnostics(from snapshots: [AXElementSnapshot]) -> FaceTimeNotificationClassificationResult {
        let ownerMatches = snapshots.filter { $0.bundleIdentifier == IncomingAnswerControlMatcher.ownerBundleIdentifier }
        let systemDialogMatches = ownerMatches.filter { snapshot in
            snapshot.ancestorChain.contains { $0.role == IncomingAnswerControlMatcher.windowRole && $0.subrole == IncomingAnswerControlMatcher.windowSubrole }
        }
        let notificationBannerMatches = systemDialogMatches.filter { snapshot in
            snapshot.ancestorChain.contains { $0.role == IncomingAnswerControlMatcher.bannerRole && $0.subrole == IncomingAnswerControlMatcher.bannerSubrole }
        }
        let bannerElements = notificationBannerMatches.filter { snapshot in
            snapshot.ancestorChain.contains { $0.axIdentifier == IncomingAnswerControlMatcher.bannerIdentifier }
        }

        let controlsDetected = bannerElements.compactMap { $0.elementDescription }.filter { knownControlDescriptions.contains($0) }

        func hasEnabledButton(description: String) -> Bool {
            bannerElements.contains { $0.role == "AXButton" && $0.enabled && $0.elementDescription == description }
        }

        let isRinging = hasEnabledButton(description: "응답") && hasEnabledButton(description: "거절")
        let isActive = hasEnabledButton(description: "종료") && (hasEnabledButton(description: "소리 끔") || hasEnabledButton(description: "키패드"))

        let state: FaceTimeNotificationCallState
        switch (isRinging, isActive) {
        case (true, true): state = .ambiguous
        case (true, false): state = .ringing
        case (false, true): state = .active
        case (false, false): state = .none
        }

        return FaceTimeNotificationClassificationResult(
            bannerFound: !bannerElements.isEmpty,
            ownerMatched: !ownerMatches.isEmpty,
            systemDialogMatched: !systemDialogMatches.isEmpty,
            notificationBannerMatched: !notificationBannerMatches.isEmpty,
            identifierMatched: !bannerElements.isEmpty,
            controlsDetected: controlsDetected,
            ringingSignatureMatched: isRinging,
            activeSignatureMatched: isActive,
            state: state
        )
    }
}
