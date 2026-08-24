import XCTest
@testable import JarvisCallBridge

@MainActor
final class SpyCallURLOpener: CallURLOpening {
    var opened: [URL] = []
    var result = true
    func open(_ url: URL) -> Bool {
        opened.append(url)
        return result
    }
}

@MainActor
final class SpyFailedCallReporter: JarvisCallReporting {
    var created: [(CallCaller, CallReportDirection)] = []
    var summaries: [String?] = []

    func createCall(origin: String, token: String, caller: CallCaller, startedAt: Date, direction: CallReportDirection) async throws -> String {
        created.append((caller, direction))
        return "call-failed"
    }

    func uploadCallAudio(origin: String, token: String, id: String, data: Data) async throws {}

    func completeCall(origin: String, token: String, id: String, endedAt: Date, transcript: [CallTranscriptTurn], uploadFailed: Bool, summary: String?) async throws {
        summaries.append(summary)
    }
}

@MainActor
final class MissedCallCallbackControllerTests: XCTestCase {
    final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    private func makeHarness(
        phone: String = "+821011122233",
        delay: TimeInterval = 3,
        workMode: Bool = true,
        autoAnswer: Bool = true
    ) -> (
        controller: MissedCallCallbackController,
        tracker: CallLifecycleTracker,
        store: UserDefaultsMissedCallCallbackStore,
        opener: SpyCallURLOpener,
        reporter: SpyFailedCallReporter,
        scanner: MockAccessibilityScanning,
        logger: BridgeLogger,
        clock: Clock,
        autoAnswer: AutoAnswerController
    ) {
        let clock = Clock()
        let logger = BridgeLogger()
        let tracker = CallLifecycleTracker(endDebounceInterval: 0.1, answerTransitionGrace: 0.1, logger: logger, now: { clock.now })
        let scanner = MockAccessibilityScanning()
        let autoAnswerController = AutoAnswerController(scanner: scanner, tracker: tracker, logger: logger)
        autoAnswerController.isEnabled = autoAnswer
        autoAnswerController.delaySeconds = delay
        let defaults = UserDefaults(suiteName: "test.callback.ctl.\(UUID().uuidString)")!
        let store = UserDefaultsMissedCallCallbackStore(defaults: defaults)
        let opener = SpyCallURLOpener()
        let reporter = SpyFailedCallReporter()
        let controller = MissedCallCallbackController(
            store: store,
            tracker: tracker,
            scanner: scanner,
            opener: opener,
            reporter: reporter,
            logger: logger,
            workModeArmed: { workMode },
            autoAnswerEnabled: { autoAnswerController.isEnabled },
            delaySeconds: { autoAnswerController.delaySeconds },
            resolveCaller: { CallCaller(name: "unknown", phoneNumber: phone) },
            loadEnv: { RealtimeEnvValues(jarvisAPIToken: "token", jarvisAPIOrigin: "https://jarvis.test") },
            now: { clock.now }
        )
        controller.waitSlice = 0
        return (controller, tracker, store, opener, reporter, scanner, logger, clock, autoAnswerController)
    }

    private func ringThenIdle(tracker: CallLifecycleTracker, clock: Clock, duration: TimeInterval) {
        tracker.update(hasAnyCandidate: true, evidence: .none)
        clock.advance(duration)
        tracker.update(hasAnyCandidate: false, evidence: .none)
        clock.advance(0.2)
        tracker.update(hasAnyCandidate: false, evidence: .none)
    }

    func testMissedLongRingEnqueuesOncePerNumber() async {
        let h = makeHarness()
        ringThenIdle(tracker: h.tracker, clock: h.clock, duration: 5)
        await h.controller.handleIncomingBecameIdle()
        ringThenIdle(tracker: h.tracker, clock: h.clock, duration: 5)
        await h.controller.handleIncomingBecameIdle()
        XCTAssertEqual(h.store.count, 1)
        XCTAssertEqual(h.store.peekOldest()?.phoneNumber, "+821011122233")
        XCTAssertTrue(h.logger.exportText().contains("[CALL-CALLBACK] result=enqueued phone=found"))
        XCTAssertFalse(h.logger.exportText().contains("+821011122233"))
    }

    func testShortRingLeavesQueueEmpty() async {
        let h = makeHarness()
        ringThenIdle(tracker: h.tracker, clock: h.clock, duration: 2)
        await h.controller.handleIncomingBecameIdle()
        XCTAssertEqual(h.store.count, 0)
        XCTAssertTrue(h.logger.exportText().contains("[CALL-CALLBACK] result=skipped"))
    }

    func testUnknownPhoneReportsNoNumberAndDoesNotEnqueue() async {
        let h = makeHarness(phone: "unknown")
        ringThenIdle(tracker: h.tracker, clock: h.clock, duration: 5)
        await h.controller.handleIncomingBecameIdle()
        XCTAssertEqual(h.store.count, 0)
        XCTAssertEqual(h.reporter.created.last?.1, .outgoing)
        XCTAssertEqual(h.reporter.summaries, ["번호 없음"])
        XCTAssertTrue(h.logger.exportText().contains("[CALL-CALLBACK] result=no_number phone=missing"))
    }

    func testTickDialsOldestOnly() async {
        let h = makeHarness()
        h.store.enqueue(phoneNumber: "+821011111111", ringingStartedAt: Date(timeIntervalSince1970: 1))
        h.store.enqueue(phoneNumber: "+821022222222", ringingStartedAt: Date(timeIntervalSince1970: 2))
        await h.controller.tick()
        XCTAssertEqual(h.opener.opened.count, 1)
        XCTAssertEqual(h.opener.opened.first?.absoluteString, "tel:+821011111111")
        XCTAssertEqual(h.store.count, 1)
        XCTAssertEqual(h.store.peekOldest()?.phoneNumber, "+821022222222")
        XCTAssertTrue(h.logger.exportText().contains("[CALL-CALLBACK] result=dial phone=found"))
        XCTAssertFalse(h.logger.exportText().contains("tel:"))
    }

    func testTickSkipsWhenRinging() async {
        let h = makeHarness()
        h.tracker.update(hasAnyCandidate: true, evidence: .none)
        h.store.enqueue(phoneNumber: "+821011111111", ringingStartedAt: Date())
        await h.controller.tick()
        XCTAssertTrue(h.opener.opened.isEmpty)
        XCTAssertEqual(h.store.count, 1)
    }

    func testTickSkipsWhenAutoAnswerOff() async {
        let h = makeHarness()
        h.autoAnswer.isEnabled = false
        h.store.enqueue(phoneNumber: "+821011111111", ringingStartedAt: Date())
        await h.controller.tick()
        XCTAssertTrue(h.opener.opened.isEmpty)
        XCTAssertEqual(h.store.count, 1)
    }

    func testTickSkipsWhenAlreadyDialing() async {
        let h = makeHarness()
        h.controller.beginDialingForTest()
        h.store.enqueue(phoneNumber: "+821011111111", ringingStartedAt: Date())
        await h.controller.tick()
        XCTAssertTrue(h.opener.opened.isEmpty)
    }

    func testNoAnswerHangsUpOnceAndReportsFixedSummary() async {
        let h = makeHarness()
        h.scanner.snapshotsToReturn = [TestSnapshots.endCallButton()]
        h.store.enqueue(phoneNumber: "+821011122233", ringingStartedAt: Date())
        await h.controller.tick()
        XCTAssertEqual(h.scanner.pressCallCount, 1)
        XCTAssertEqual(h.scanner.pressedSnapshotIDs, ["end-call-1"])
        XCTAssertEqual(h.reporter.summaries, ["콜백 연결 안 됨"])
        XCTAssertEqual(h.reporter.created.last?.1, .outgoing)
        XCTAssertFalse(h.controller.isDialing)
        XCTAssertEqual(h.store.count, 0)
        XCTAssertTrue(h.logger.exportText().contains("[CALL-CALLBACK] result=no_answer phone=found"))
        XCTAssertTrue(h.logger.exportText().contains("[CALL-CALLBACK] result=hangup phone=found"))
        XCTAssertFalse(h.logger.exportText().contains("+821011122233"))
    }

    func testTelOpenFailureStillReportsNoAnswer() async {
        let h = makeHarness()
        h.opener.result = false
        h.store.enqueue(phoneNumber: "+821011122233", ringingStartedAt: Date())
        await h.controller.tick()
        XCTAssertEqual(h.reporter.summaries, ["콜백 연결 안 됨"])
        XCTAssertEqual(h.store.count, 0)
    }

    func testAmbiguousEndCallDoesNotPressButStillReports() async {
        let h = makeHarness()
        h.scanner.snapshotsToReturn = [
            TestSnapshots.endCallButton(id: "end-1"),
            TestSnapshots.endCallButton(id: "end-2"),
        ]
        h.store.enqueue(phoneNumber: "+821011122233", ringingStartedAt: Date())
        await h.controller.tick()
        XCTAssertEqual(h.scanner.pressCallCount, 0)
        XCTAssertEqual(h.reporter.summaries, ["콜백 연결 안 됨"])
    }

    func testActiveBeforeTimeoutDoesNotHangup() async {
        let h = makeHarness()
        h.scanner.snapshotsToReturn = [TestSnapshots.endCallButton()]
        h.store.enqueue(phoneNumber: "+821011122233", ringingStartedAt: Date())
        h.controller.onDidDial = {
            h.tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        }
        await h.controller.tick()
        XCTAssertEqual(h.scanner.pressCallCount, 0)
        XCTAssertTrue(h.reporter.summaries.isEmpty)
        XCTAssertFalse(h.controller.isDialing)
        XCTAssertTrue(h.logger.exportText().contains("[CALL-CALLBACK] result=connected phone=found"))
    }

    func testActiveSessionDoesNotEnqueue() async {
        let h = makeHarness()
        h.tracker.update(hasAnyCandidate: true, evidence: .none)
        h.tracker.update(hasAnyCandidate: false, evidence: TestSnapshots.activeEvidence)
        h.tracker.update(hasAnyCandidate: false, evidence: .none)
        h.clock.advance(0.2)
        h.tracker.update(hasAnyCandidate: false, evidence: .none)
        await h.controller.handleIncomingBecameIdle()
        XCTAssertEqual(h.store.count, 0)
        XCTAssertTrue(h.logger.exportText().contains("[CALL-CALLBACK] result=skipped"))
    }
}
