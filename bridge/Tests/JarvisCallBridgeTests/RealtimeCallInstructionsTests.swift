import XCTest
@testable import JarvisCallBridge

final class RealtimeCallInstructionsTests: XCTestCase {
    func testPoliteComposeIncludesHonorificLineAndNotCasual() {
        let text = RealtimeCallInstructions.compose(style: .polite, extra: "")
        XCTAssertTrue(text.contains(OpenAIRealtimeVoiceAdapter.defaultInstructions))
        XCTAssertTrue(text.contains(RealtimeCallInstructions.politeLine))
        XCTAssertFalse(text.contains(RealtimeCallInstructions.casualLine))
    }

    func testCasualComposeIncludesCasualLineAndNotHonorific() {
        let text = RealtimeCallInstructions.compose(style: .casual, extra: "  ")
        XCTAssertTrue(text.contains(RealtimeCallInstructions.casualLine))
        XCTAssertFalse(text.contains(RealtimeCallInstructions.politeLine))
    }

    func testExtraAppendsAfterStyle() {
        let text = RealtimeCallInstructions.compose(style: .polite, extra: "용건만 묻고 끊으세요.")
        XCTAssertTrue(text.contains("용건만 묻고 끊으세요."))
        XCTAssertTrue(text.contains(RealtimeCallInstructions.politeLine))
    }

    func testEmptyExtraUsesDefaultOpeningVerbatim() {
        let text = RealtimeCallInstructions.compose(style: .polite, extra: "")
        XCTAssertTrue(text.contains(RealtimeCallInstructions.defaultOpening))
        XCTAssertTrue(text.contains(RealtimeCallInstructions.verbatimOpeningLine))
        XCTAssertTrue(text.contains(RealtimeCallInstructions.openingOnceLine))
    }

    func testFollowUpDropsTheOpeningAndForbidsRepeatingIt() {
        let followUp = RealtimeCallInstructions.composeAfterOpening(style: .polite)
        XCTAssertFalse(followUp.contains(RealtimeCallInstructions.defaultOpening))
        XCTAssertFalse(followUp.contains(RealtimeCallInstructions.verbatimOpeningLine))
        XCTAssertTrue(followUp.contains(RealtimeCallInstructions.alreadyGreetedLine))
        XCTAssertTrue(followUp.contains(RealtimeCallInstructions.politeLine))
    }

    func testCustomExtraIsTheOpeningNotTheDefault() {
        let text = RealtimeCallInstructions.compose(style: .polite, extra: "여보세요.")
        XCTAssertTrue(text.contains("여보세요."))
        XCTAssertFalse(text.contains(RealtimeCallInstructions.defaultOpening))
        XCTAssertTrue(text.contains(RealtimeCallInstructions.verbatimOpeningLine))
    }

    func testExtraLongerThanLimitIsTrimmed() {
        let extra = String(repeating: "가", count: RealtimeCallInstructions.extraLimit + 20)
        let stored = RealtimeCallInstructions.normalizedExtra(extra)
        XCTAssertEqual(stored.count, RealtimeCallInstructions.extraLimit)
    }

    func testUnknownStoredStyleFallsBackToPolite() {
        XCTAssertEqual(RealtimeSpeechStyle.parse("yelling"), .polite)
        XCTAssertEqual(RealtimeSpeechStyle.parse("casual"), .casual)
    }

    func testStoreRoundTripsIncomingAndOutgoingSeparately() {
        let defaults = UserDefaults(suiteName: "test.realtime.instructions.\(UUID().uuidString)")!
        let store = UserDefaultsRealtimeCallInstructionStore(defaults: defaults)
        store.speechStyle = .casual
        store.incomingGreeting = "  수신 인사  "
        store.outgoingGreeting = "  발신 인사  "
        XCTAssertEqual(store.incomingGreeting, "수신 인사")
        XCTAssertEqual(store.outgoingGreeting, "발신 인사")
        XCTAssertTrue(store.composedInstructions().contains("수신 인사"))
        XCTAssertFalse(store.composedInstructions().contains("발신 인사"))
    }

    func testStoreMigratesLegacyExtraToIncoming() {
        let defaults = UserDefaults(suiteName: "test.realtime.instructions.\(UUID().uuidString)")!
        defaults.set("예전 추가 프롬프트", forKey: RealtimeCallInstructions.extraKey)
        let store = UserDefaultsRealtimeCallInstructionStore(defaults: defaults)
        XCTAssertEqual(store.incomingGreeting, "예전 추가 프롬프트")
        XCTAssertEqual(store.outgoingGreeting, "")
    }

    func testOutgoingEmptyDoesNotUseIncomingDefaultOpening() {
        let text = RealtimeCallInstructions.composeOutgoing(style: .polite, extra: "")
        XCTAssertTrue(text.contains(OpenAIRealtimeVoiceAdapter.defaultInstructions))
        XCTAssertTrue(text.contains(RealtimeCallInstructions.politeLine))
        XCTAssertFalse(text.contains(RealtimeCallInstructions.defaultOpening))
        XCTAssertFalse(text.contains(RealtimeCallInstructions.verbatimOpeningLine))
    }

    func testOutgoingExtraIsSpokenVerbatim() {
        let text = RealtimeCallInstructions.composeOutgoing(style: .casual, extra: "다시 연락드렸습니다.")
        XCTAssertTrue(text.contains("다시 연락드렸습니다."))
        XCTAssertTrue(text.contains(RealtimeCallInstructions.verbatimOpeningLine))
        XCTAssertFalse(text.contains(RealtimeCallInstructions.defaultOpening))
    }

    func testStoreComposedOutgoingUsesOutgoingGreetingOnly() {
        let defaults = UserDefaults(suiteName: "test.realtime.instructions.\(UUID().uuidString)")!
        let store = UserDefaultsRealtimeCallInstructionStore(defaults: defaults)
        store.incomingGreeting = "수신 인사"
        store.outgoingGreeting = "발신 인사"
        XCTAssertTrue(store.composedInstructions(direction: .outgoing).contains("발신 인사"))
        XCTAssertFalse(store.composedInstructions(direction: .outgoing).contains("수신 인사"))
        XCTAssertFalse(store.composedInstructions(direction: .outgoing).contains(RealtimeCallInstructions.defaultOpening))
    }

    func testConnectLogHasNoExtraBody() {
        let line = RealtimeCallInstructions.connectLog(style: .polite, extra: "비밀 지시문")
        XCTAssertEqual(line, "[CALL] realtime instructions style=polite extra=set")
        XCTAssertFalse(line.contains("비밀"))
        XCTAssertEqual(RealtimeCallInstructions.connectLog(style: .casual, extra: "  "), "[CALL] realtime instructions style=casual extra=empty")
    }
}
