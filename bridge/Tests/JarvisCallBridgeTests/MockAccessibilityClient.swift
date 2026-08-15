import Foundation
@testable import JarvisCallBridge

/// Test double for `AccessibilityScanning`. No real Accessibility framework call anywhere in this
/// file — every Call-lifecycle unit test drives this instead (PRD §29).
final class MockAccessibilityScanning: AccessibilityScanning {
    var snapshotsToReturn: [AXElementSnapshot] = []
    var evidenceToReturn: CallStateEvidence = .none
    var pressResult: AccessibilityPressResult = .success

    private(set) var pressCallCount = 0
    private(set) var pressedSnapshotIDs: [String] = []

    func scanCallRelevantElements() -> [AXElementSnapshot] { snapshotsToReturn }
    func currentCallStateEvidence() -> CallStateEvidence { evidenceToReturn }

    func press(_ snapshot: AXElementSnapshot) -> AccessibilityPressResult {
        pressCallCount += 1
        pressedSnapshotIDs.append(snapshot.id)
        return pressResult
    }
}

enum TestSnapshots {
    /// The real-device evidence-locked ancestor chain (CHECKPOINT 3): window `AXSystemDialog`,
    /// then the `AXNotificationCenterBanner`/`FACETIME_NOTIFICATION` group, nearest-first.
    static let facetimeNotificationAncestorChain: [AXAncestorDescriptor] = [
        AXAncestorDescriptor(role: IncomingAnswerControlMatcher.bannerRole, subrole: IncomingAnswerControlMatcher.bannerSubrole, axIdentifier: IncomingAnswerControlMatcher.bannerIdentifier),
        AXAncestorDescriptor(role: IncomingAnswerControlMatcher.windowRole, subrole: IncomingAnswerControlMatcher.windowSubrole, axIdentifier: nil)
    ]

    private static func facetimeNotificationBannerControl(
        id: String, pid: pid_t, description: String, role: String = "AXButton",
        enabled: Bool = true, actions: [String] = ["AXPress"],
        bundleIdentifier: String = IncomingAnswerControlMatcher.ownerBundleIdentifier,
        ancestorChain: [AXAncestorDescriptor] = TestSnapshots.facetimeNotificationAncestorChain
    ) -> AXElementSnapshot {
        AXElementSnapshot(
            id: id, pid: pid, bundleIdentifier: bundleIdentifier,
            role: role, subrole: nil, axIdentifier: nil,
            title: nil, elementDescription: description, enabled: enabled,
            actions: actions, firstObservedAt: Date(), ancestorChain: ancestorChain
        )
    }

    /// The real observed Answer control: `com.apple.notificationcenterui` /
    /// `AXWindow(AXSystemDialog)` / `AXGroup(AXNotificationCenterBanner, FACETIME_NOTIFICATION)` /
    /// `AXButton(description="응답")`, enabled, AXPress-capable — the only shape
    /// `IncomingAnswerControlMatcher` accepts as high confidence.
    static func highConfidenceAnswerButton(id: String = "answer-1", pid: pid_t = 1001) -> AXElementSnapshot {
        facetimeNotificationBannerControl(id: id, pid: pid, description: IncomingAnswerControlMatcher.answerDescription)
    }

    /// The real observed Reject sibling — same banner, same process, but description="거절". Must
    /// never become an `AnswerCandidate`.
    static func rejectButton(id: String = "reject-1", pid: pid_t = 1001) -> AXElementSnapshot {
        facetimeNotificationBannerControl(id: id, pid: pid, description: "거절")
    }

    /// The real observed Reply sibling — description="답장". Must never become an `AnswerCandidate`.
    static func replyButton(id: String = "reply-1", pid: pid_t = 1001) -> AXElementSnapshot {
        facetimeNotificationBannerControl(id: id, pid: pid, description: "답장")
    }

    /// The real observed "More" sibling — role=AXPopUpButton, description="더 보기". Must never
    /// become an `AnswerCandidate`.
    static func moreButton(id: String = "more-1", pid: pid_t = 1001) -> AXElementSnapshot {
        facetimeNotificationBannerControl(id: id, pid: pid, description: "더 보기", role: "AXPopUpButton")
    }

    /// The exact "응답" button/process, but structurally *outside* the FACETIME_NOTIFICATION
    /// banner (no ancestor chain at all) — must not qualify. Proves the ancestry check, not just
    /// the description check, is load-bearing.
    static func answerButtonOutsideBanner(id: String = "answer-outside", pid: pid_t = 1001) -> AXElementSnapshot {
        facetimeNotificationBannerControl(id: id, pid: pid, description: IncomingAnswerControlMatcher.answerDescription, ancestorChain: [])
    }

    /// The exact FACETIME_NOTIFICATION banner shape, but owned by an unrelated process — must not
    /// qualify. Proves the owning-process check is load-bearing, not just the banner ancestry.
    static func answerButtonUnderUnrelatedProcess(id: String = "answer-wrong-process", pid: pid_t = 9009) -> AXElementSnapshot {
        facetimeNotificationBannerControl(id: id, pid: pid, description: IncomingAnswerControlMatcher.answerDescription, bundleIdentifier: "com.example.other")
    }

    /// Never becomes a candidate at all: generic enabled button with no evidence-locked structural
    /// match — exactly the shape of the 341 false-positive elements from the real no-call
    /// baseline (Edit/Filter/Keypad/Search/window chrome).
    static func lowConfidenceButton(id: String = "low-1", pid: pid_t = 3003) -> AXElementSnapshot {
        AXElementSnapshot(
            id: id, pid: pid, bundleIdentifier: "com.example.other",
            role: "AXButton", subrole: nil, axIdentifier: nil,
            title: "OK", elementDescription: nil, enabled: true,
            actions: ["AXPress"], firstObservedAt: Date()
        )
    }

    static let activeEvidence = CallStateEvidence(
        answerButtonPresent: false, endCallButtonPresent: true,
        activeCallControlsPresent: true, callDurationUIPresent: false
    )

    /// One ordinary, always-present Phone.app dialer/window-chrome control — enabled, pressable,
    /// AXButton, but with no evidence-locked structural match. This is the exact shape of the
    /// 341 false-positive elements from the real CHECKPOINT 2 no-call baseline.
    static func ordinaryPhoneAppControl(id: String, title: String? = nil, description: String? = nil, subrole: String? = nil) -> AXElementSnapshot {
        AXElementSnapshot(
            id: id, pid: 4004, bundleIdentifier: AnswerCandidateResolver.phoneAppBundleIdentifier,
            role: "AXButton", subrole: subrole, axIdentifier: nil,
            title: title, elementDescription: description, enabled: true,
            actions: ["AXPress"], firstObservedAt: Date()
        )
    }

    /// The full real-device no-call baseline shape (§7/§8 of the CHECKPOINT 2 false-positive
    /// report): Edit/Filter/Keypad/Search plus window-chrome Close/Zoom/Minimize buttons. None of
    /// these should ever become a candidate or produce call-state evidence.
    static func noCallBaselineFixture() -> [AXElementSnapshot] {
        [
            ordinaryPhoneAppControl(id: "edit", title: "편집"),
            ordinaryPhoneAppControl(id: "filter", title: "필터"),
            ordinaryPhoneAppControl(id: "keypad", title: "키패드"),
            ordinaryPhoneAppControl(id: "search", title: "검색"),
            ordinaryPhoneAppControl(id: "close", description: "닫기", subrole: "AXCloseButton"),
            ordinaryPhoneAppControl(id: "zoom", description: "확대/축소", subrole: "AXZoomButton"),
            ordinaryPhoneAppControl(id: "minimize", description: "최소화", subrole: "AXMinimizeButton")
        ]
    }

    /// The full real-device FACETIME_NOTIFICATION banner, minus Answer — Reject/Reply/More plus
    /// the generic "전화"/caller-name informational elements. §21 regression: Notification Center
    /// content that isn't the banner (or a banner without Answer) must never yield a candidate.
    static func notificationCenterBannerWithoutAnswer() -> [AXElementSnapshot] {
        [rejectButton(), replyButton(), moreButton()]
    }

    /// The one transient element observed correlating with a real incoming call — diagnostic clue
    /// only, deliberately outside both the answer-keyword and call-subrole gates.
    static func callPresenceHintElement(id: String = "call-presence-hint") -> AXElementSnapshot {
        ordinaryPhoneAppControl(id: id, description: "통신 오디오")
    }

    // MARK: - CHECKPOINT 3 Active Call Evidence Fix: real observed active-call banner

    static func endCallButton(id: String = "end-call-1", pid: pid_t = 1001) -> AXElementSnapshot {
        facetimeNotificationBannerControl(id: id, pid: pid, description: "종료")
    }

    static func muteButton(id: String = "mute-1", pid: pid_t = 1001) -> AXElementSnapshot {
        facetimeNotificationBannerControl(id: id, pid: pid, description: "소리 끔")
    }

    /// Same "키패드" label as the CHECKPOINT 2 no-call false positive, but this one is genuinely
    /// inside the real FACETIME_NOTIFICATION banner — the structural distinction (banner ancestry,
    /// not the label itself) is exactly what makes this legitimate active-call evidence while the
    /// bare Phone.app one in `noCallBaselineFixture()` never is.
    static func keypadButtonInBanner(id: String = "keypad-banner-1", pid: pid_t = 1001) -> AXElementSnapshot {
        facetimeNotificationBannerControl(id: id, pid: pid, description: "키패드")
    }

    /// Observed disabled in the one real active-call capture — recorded as diagnostic data only,
    /// never required for Active classification (its enabled state may vary).
    static func faceTimeVideoCallButtonDisabled(id: String = "facetime-video-1", pid: pid_t = 1001) -> AXElementSnapshot {
        facetimeNotificationBannerControl(id: id, pid: pid, description: "FaceTime 영상 통화", enabled: false)
    }

    /// The real observed ringing banner: 응답 + 거절 (+ incidental 답장/더 보기 siblings, per §14
    /// never used to distinguish state).
    static func ringingCallBannerFixture() -> [AXElementSnapshot] {
        [highConfidenceAnswerButton(), rejectButton(), replyButton(), moreButton()]
    }

    /// The real observed active-call banner, captured after a genuine manual answer connected the
    /// call: 응답/거절 are gone, replaced by 종료/소리 끔/키패드 (+ disabled FaceTime 영상 통화,
    /// + incidental 더 보기).
    static func activeCallBannerFixture() -> [AXElementSnapshot] {
        [endCallButton(), muteButton(), keypadButtonInBanner(), faceTimeVideoCallButtonDisabled(), moreButton()]
    }
}
