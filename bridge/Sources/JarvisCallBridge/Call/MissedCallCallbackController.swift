import Foundation

@MainActor
final class MissedCallCallbackController: ObservableObject {
    @Published var intervalMinutes: Int {
        didSet {
            store.intervalMinutes = intervalMinutes
            restartTimerIfRunning()
        }
    }
    @Published var noAnswerSeconds: Int {
        didSet { store.noAnswerSeconds = noAnswerSeconds }
    }
    @Published private(set) var queueCount: Int = 0
    private(set) var isDialing = false
    var waitSlice: TimeInterval = 0.05
    var onDidDial: (() -> Void)?
    weak var realtimeSession: OpenAIRealtimeVoiceSessionController?

    private let store: MissedCallCallbackStoring
    private let tracker: CallLifecycleTracker
    private let scanner: AccessibilityScanning
    private let opener: CallURLOpening
    private let reporter: JarvisCallReporting
    private let logger: BridgeLogger
    private let workModeArmed: () -> Bool
    private let autoAnswerEnabled: () -> Bool
    private let delaySeconds: () -> TimeInterval
    private let resolveCaller: () -> CallCaller
    private let loadEnv: () -> RealtimeEnvValues
    private let now: () -> Date
    private var timer: Timer?
    private var timerRunning = false

    init(
        store: MissedCallCallbackStoring,
        tracker: CallLifecycleTracker,
        scanner: AccessibilityScanning,
        opener: CallURLOpening,
        reporter: JarvisCallReporting,
        logger: BridgeLogger,
        workModeArmed: @escaping () -> Bool,
        autoAnswerEnabled: @escaping () -> Bool,
        delaySeconds: @escaping () -> TimeInterval,
        resolveCaller: @escaping () -> CallCaller,
        loadEnv: @escaping () -> RealtimeEnvValues,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.tracker = tracker
        self.scanner = scanner
        self.opener = opener
        self.reporter = reporter
        self.logger = logger
        self.workModeArmed = workModeArmed
        self.autoAnswerEnabled = autoAnswerEnabled
        self.delaySeconds = delaySeconds
        self.resolveCaller = resolveCaller
        self.loadEnv = loadEnv
        self.now = now
        self.intervalMinutes = store.intervalMinutes
        self.noAnswerSeconds = store.noAnswerSeconds
        self.queueCount = store.count
    }

    func handleIncomingBecameIdle() async {
        guard let outcome = tracker.lastOutcome else { return }
        let caller = resolveCaller()
        let decision = MissedCallCallbackDecision.evaluate(
            MissedCallCallbackInput(
                workModeOn: workModeArmed(),
                autoAnswerOn: autoAnswerEnabled(),
                reachedActive: outcome.reachedActive,
                ringingDuration: outcome.endedAt.timeIntervalSince(outcome.startedAt),
                delaySeconds: delaySeconds(),
                phoneNumber: caller.phoneNumber
            )
        )
        let phoneFlag = caller.phoneNumber == "unknown" || caller.phoneNumber.isEmpty ? "missing" : "found"
        switch decision {
        case .enqueue(let phoneNumber):
            store.enqueue(phoneNumber: phoneNumber, ringingStartedAt: outcome.startedAt)
            queueCount = store.count
            logger.log("[CALL-CALLBACK] result=enqueued phone=\(phoneFlag)")
        case .reportNoNumber:
            await reportFailed(caller: caller, summary: "번호 없음")
            logger.log("[CALL-CALLBACK] result=no_number phone=missing")
        case .skip:
            logger.log("[CALL-CALLBACK] result=skipped phone=\(phoneFlag)")
        }
    }

    func noteIncomingRinging() {
        guard !isDialing else { return }
        realtimeSession?.reportDirection = .incoming
    }

    func beginDialingForTest() {
        isDialing = true
    }

    func start() {
        stop()
        timerRunning = true
        let interval = TimeInterval(max(1, store.intervalMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        timerRunning = false
    }

    func tick() async {
        guard autoAnswerEnabled(), workModeArmed() else { return }
        switch tracker.state {
        case .ringing, .answering, .active, .ending:
            return
        default:
            break
        }
        guard !isDialing, let item = store.popOldest() else { return }
        queueCount = store.count
        guard let url = CallTelURL.make(phoneNumber: item.phoneNumber) else {
            await reportFailed(caller: CallCaller(name: "unknown", phoneNumber: item.phoneNumber), summary: "콜백 연결 안 됨")
            return
        }
        isDialing = true
        realtimeSession?.reportDirection = .outgoing
        let opened = opener.open(url)
        logger.log("[CALL-CALLBACK] result=dial phone=found")
        onDidDial?()
        if opened {
            await waitForAnswer(phoneNumber: item.phoneNumber)
        } else {
            await finishUnanswered(phoneNumber: item.phoneNumber)
        }
    }

    private func waitForAnswer(phoneNumber: String) async {
        let deadline = now().addingTimeInterval(TimeInterval(store.noAnswerSeconds))
        if waitSlice <= 0 {
            if tracker.state == .active {
                logger.log("[CALL-CALLBACK] result=connected phone=found")
                isDialing = false
                return
            }
            await finishUnanswered(phoneNumber: phoneNumber)
            return
        }
        while now() < deadline {
            if tracker.state == .active {
                logger.log("[CALL-CALLBACK] result=connected phone=found")
                isDialing = false
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(waitSlice * 1_000_000_000))
        }
        await finishUnanswered(phoneNumber: phoneNumber)
    }

    private func finishUnanswered(phoneNumber: String) async {
        logger.log("[CALL-CALLBACK] result=no_answer phone=found")
        let high = EndCallCandidateResolver.resolve(from: scanner.scanCallRelevantElements())
            .filter { $0.confidence == .high }
        if high.count == 1, let end = high.first {
            _ = scanner.press(end.snapshot)
            logger.log("[CALL-CALLBACK] result=hangup phone=found")
        }
        await reportFailed(caller: CallCaller(name: "unknown", phoneNumber: phoneNumber), summary: "콜백 연결 안 됨")
        isDialing = false
    }

    private func restartTimerIfRunning() {
        if timerRunning { start() }
    }

    private func reportFailed(caller: CallCaller, summary: String) async {
        let env = loadEnv()
        guard let token = env.jarvisAPIToken, !token.isEmpty,
              let origin = env.jarvisAPIOrigin, !origin.isEmpty
        else { return }
        do {
            let id = try await reporter.createCall(
                origin: origin,
                token: token,
                caller: caller,
                startedAt: now(),
                direction: .outgoing
            )
            try await reporter.completeCall(
                origin: origin,
                token: token,
                id: id,
                endedAt: now(),
                transcript: [],
                uploadFailed: true,
                summary: summary
            )
        } catch {
            logger.log("[CALL-CALLBACK] result=skipped phone=found")
        }
    }
}
