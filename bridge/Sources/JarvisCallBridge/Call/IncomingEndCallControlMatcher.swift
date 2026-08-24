import Foundation

enum IncomingEndCallControlMatcher {
    static let ownerBundleIdentifier = IncomingAnswerControlMatcher.ownerBundleIdentifier
    static let windowRole = IncomingAnswerControlMatcher.windowRole
    static let windowSubrole = IncomingAnswerControlMatcher.windowSubrole
    static let bannerRole = IncomingAnswerControlMatcher.bannerRole
    static let bannerSubrole = IncomingAnswerControlMatcher.bannerSubrole
    static let bannerIdentifier = IncomingAnswerControlMatcher.bannerIdentifier
    static let endDescription = "종료"

    static func isEvidenceLockedEndCallControl(_ snapshot: AXElementSnapshot) -> Bool {
        guard snapshot.bundleIdentifier == ownerBundleIdentifier else { return false }
        guard snapshot.ancestorChain.contains(where: { $0.role == windowRole && $0.subrole == windowSubrole }) else { return false }
        guard snapshot.ancestorChain.contains(where: { $0.role == bannerRole && $0.subrole == bannerSubrole && $0.axIdentifier == bannerIdentifier }) else { return false }
        guard snapshot.role == "AXButton" else { return false }
        guard snapshot.elementDescription == endDescription else { return false }
        guard snapshot.enabled else { return false }
        guard snapshot.supportsPress else { return false }
        return true
    }
}
