import Foundation

/// CHECKPOINT 3 — Evidence-Locked Answer Control matching. Real-device evidence (2026-08-15)
/// identified the exact incoming-call Answer control on the currently validated Korean macOS
/// system:
///
///   process bundle   = com.apple.notificationcenterui
///   window            AXWindow / subrole=AXSystemDialog
///   banner ancestor    AXGroup / subrole=AXNotificationCenterBanner / identifier=FACETIME_NOTIFICATION
///   target             AXButton / description="응답" / enabled=true / actions ⊇ [AXPress]
///
/// A candidate is HIGH confidence only when **all** of these structural signals match — never a
/// subset, and never from generic score accumulation (CHECKPOINT 2's "enabled + owning process +
/// role" scoring already proved insufficient — a real no-call baseline produced 341 false
/// positives from exactly that kind of generic match). This is deliberately narrow: real evidence
/// beats guessed localization — no additional label ("받기"/"수락"/"Answer"/"Accept") is added
/// without its own captured real-device evidence. Sibling banner controls ("거절"/"답장"/"더 보기")
/// and the earlier "통신 오디오" diagnostic clue are all structurally excluded by the `description`
/// and role checks below.
enum IncomingAnswerControlMatcher {
    static let ownerBundleIdentifier = "com.apple.notificationcenterui"
    static let windowRole = "AXWindow"
    static let windowSubrole = "AXSystemDialog"
    static let bannerRole = "AXGroup"
    static let bannerSubrole = "AXNotificationCenterBanner"
    static let bannerIdentifier = "FACETIME_NOTIFICATION"
    static let answerDescription = "응답"

    static func isEvidenceLockedAnswerControl(_ snapshot: AXElementSnapshot) -> Bool {
        guard snapshot.bundleIdentifier == ownerBundleIdentifier else { return false }
        guard snapshot.ancestorChain.contains(where: { $0.role == windowRole && $0.subrole == windowSubrole }) else { return false }
        guard snapshot.ancestorChain.contains(where: { $0.role == bannerRole && $0.subrole == bannerSubrole && $0.axIdentifier == bannerIdentifier }) else { return false }
        guard snapshot.role == "AXButton" else { return false }
        guard snapshot.elementDescription == answerDescription else { return false }
        guard snapshot.enabled else { return false }
        guard snapshot.supportsPress else { return false }
        return true
    }
}
