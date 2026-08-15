import Foundation

enum CandidateConfidence: String, Comparable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (lhs: CandidateConfidence, rhs: CandidateConfidence) -> Bool { lhs.rank < rhs.rank }
}

struct AnswerCandidate: Equatable, Identifiable {
    let snapshot: AXElementSnapshot
    let confidence: CandidateConfidence
    let evidence: [String]

    var id: String { snapshot.id }
}

/// CHECKPOINT 3: candidacy is now decided entirely by `IncomingAnswerControlMatcher` — real
/// evidence-locked structural matching (owning process + window subrole + banner ancestor +
/// target role/description/enabled/AXPress), not the CHECKPOINT 2-era generic score
/// accumulation. That heuristic already proved insufficient: a real no-call baseline showed
/// "enabled + owning process is Phone.app + role=AXButton" alone was enough to cross its medium
/// threshold for 341 ordinary elements. Under evidence-locked matching there is no partial
/// credit — an element either matches the full real-device shape (⇒ high confidence) or it isn't
/// a candidate at all (never low, never a weaker "maybe").
///
/// Per PRD §13, ambiguity is still resolved by refusing confidence, never by guessing: if more
/// than one element independently matches, all of them are downgraded to medium — a single
/// unambiguous high-confidence candidate is required before `AutoAnswerController` will ever act.
enum AnswerCandidateResolver {
    /// Retained for callers/tests that still reference "the Phone.app bundle" as a concept (e.g.
    /// constructing regression fixtures for ordinary, non-call-relevant Phone.app UI) — no longer
    /// used internally by `resolve`, since candidacy is now owned entirely by
    /// `IncomingAnswerControlMatcher`.
    static let phoneAppBundleIdentifier = "com.apple.mobilephone"

    static func resolve(from snapshots: [AXElementSnapshot]) -> [AnswerCandidate] {
        let matched = snapshots.filter { IncomingAnswerControlMatcher.isEvidenceLockedAnswerControl($0) }

        if matched.count > 1 {
            return matched.map {
                AnswerCandidate(
                    snapshot: $0, confidence: .medium,
                    evidence: ["downgraded: multiple ambiguous evidence-locked candidates"]
                )
            }
        }

        return matched.map {
            AnswerCandidate(
                snapshot: $0, confidence: .high,
                evidence: [
                    "owner=\(IncomingAnswerControlMatcher.ownerBundleIdentifier)",
                    "window=\(IncomingAnswerControlMatcher.windowSubrole)",
                    "banner=\(IncomingAnswerControlMatcher.bannerIdentifier)",
                    "control=\(IncomingAnswerControlMatcher.answerDescription)"
                ]
            )
        }
    }
}
