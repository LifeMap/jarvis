import Foundation

/// Pure, unit-testable evidence extraction — mirrors `AnswerCandidateResolver`'s separation of
/// "scoring logic" from "how the snapshots were obtained" (PRD §29), so this can be tested with
/// plain `AXElementSnapshot` fixtures instead of requiring real Accessibility framework access.
///
/// CHECKPOINT 2 false-positive fix: a confirmed real no-call baseline produced
/// `answer=true end=true activeControls=true duration=true` from 341 ordinary Phone.app/
/// Notification Center elements — root cause was global keyword matching ("종료"/"키패드"/etc.
/// matching *anywhere*, not just inside real call UI).
///
/// CHECKPOINT 3 Active Call Evidence Fix: a real Gate A manual-answer test showed the native call
/// connected but Jarvis never recognized Active — because CHECKPOINT 2's fix for the false
/// positives had *removed* "종료"/"키패드" from the global keyword lists entirely (they were false
/// positives when matched globally), leaving no path to recognize them as evidence even when they
/// legitimately appear inside the real, evidence-locked `FACETIME_NOTIFICATION` banner during an
/// active call. The correct fix on both counts is the same: these labels only have call semantics
/// when scoped to that specific banner — never as a global keyword. `end`/`activeControls`
/// evidence is now derived entirely from `FaceTimeNotificationCallStateClassifier`'s structural,
/// banner-scoped signature (verified "종료" AND at least one of "소리 끔"/"키패드", both enabled,
/// both inside the real banner) rather than any keyword search over all scanned text.
enum CallStateEvidenceExtractor {
    static func extract(from elements: [AXElementSnapshot]) -> CallStateEvidence {
        let answerPresent = !AnswerCandidateResolver.resolve(from: elements).isEmpty

        // "종료" being present and enabled means an active call *has an available end-call
        // control* — it is never, by itself or via any keyword search, evidence that the call
        // already ended. Only the verified two-signal active banner signature counts.
        let verifiedActive = FaceTimeNotificationCallStateClassifier.classify(from: elements) == .active
        let endPresent = verifiedActive
        let activeControlsPresent = verifiedActive

        let durationPresent = elements.contains { snapshot in
            snapshot.enabled && (looksLikeCallDuration(snapshot.title) || looksLikeCallDuration(snapshot.elementDescription))
        }

        return CallStateEvidence(
            answerButtonPresent: answerPresent,
            endCallButtonPresent: endPresent,
            activeCallControlsPresent: activeControlsPresent,
            callDurationUIPresent: durationPresent
        )
    }

    /// Requires the *entire* candidate string to be a clean MM:SS or H:MM:SS numeric duration —
    /// guards against arbitrary colon-containing text (timestamps, labels, shortcuts) counting as
    /// evidence.
    static func looksLikeCallDuration(_ text: String?) -> Bool {
        guard let trimmed = text?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return false }
        return trimmed.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }
}
