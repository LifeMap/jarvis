import Foundation

enum EndCallCandidateResolver {
    static func resolve(from snapshots: [AXElementSnapshot]) -> [AnswerCandidate] {
        let matched = snapshots.filter { IncomingEndCallControlMatcher.isEvidenceLockedEndCallControl($0) }

        if matched.count > 1 {
            return matched.map {
                AnswerCandidate(
                    snapshot: $0,
                    confidence: .medium,
                    evidence: ["downgraded: multiple ambiguous evidence-locked candidates"]
                )
            }
        }

        return matched.map {
            AnswerCandidate(
                snapshot: $0,
                confidence: .high,
                evidence: [
                    "owner=\(IncomingEndCallControlMatcher.ownerBundleIdentifier)",
                    "window=\(IncomingEndCallControlMatcher.windowSubrole)",
                    "banner=\(IncomingEndCallControlMatcher.bannerIdentifier)",
                    "control=\(IncomingEndCallControlMatcher.endDescription)",
                ]
            )
        }
    }
}
