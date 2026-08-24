import XCTest
@testable import JarvisCallBridge

final class CallCallerIdentityTests: XCTestCase {
    func testSavedContactUsesNameAndNumber() {
        let caller = CallCallerIdentity.resolve(
            texts: ["010-1234-5678", "응답"],
            contactName: { $0.contains("1234") ? "김민수" : nil }
        )
        XCTAssertEqual(caller, CallCaller(name: "김민수", phoneNumber: "+821012345678"))
    }

    func testUnknownContactKeepsNumber() {
        let caller = CallCallerIdentity.resolve(texts: ["+82 10-9999-0000"], contactName: { _ in nil })
        XCTAssertEqual(caller.name, "unknown")
        XCTAssertEqual(caller.phoneNumber, "+821099990000")
    }

    func testNameOnlyBannerLeavesPhoneUnknown() {
        let caller = CallCallerIdentity.resolve(texts: ["거래처 담당", "응답", "거절"], contactName: { _ in nil })
        XCTAssertEqual(caller, CallCaller(name: "거래처 담당", phoneNumber: "unknown"))
    }

    func testMissingEverythingIsUnknown() {
        let caller = CallCallerIdentity.resolve(texts: ["응답", "거절"], contactName: { _ in nil })
        XCTAssertEqual(caller, .unknown)
    }

    func testIngestKeepsAPhoneAfterLaterTicksHaveOnlyControls() {
        let resolver = StoredCallCallerResolver()
        resolver.ingest(["010-1234-5678", "응답"])
        resolver.ingest(["종료", "키패드", "소리 끔"])
        XCTAssertEqual(resolver.resolve().phoneNumber, "+821012345678")
    }

    func testResetClearsAPreviousCallPhone() {
        let resolver = StoredCallCallerResolver()
        resolver.ingest(["010-1234-5678"])
        resolver.reset()
        XCTAssertEqual(resolver.resolve(), .unknown)
    }

    func testIdentityTextsReadAPhoneFromStaticValue() {
        let texts = CallCallerIdentity.identityTexts(title: nil, description: "이름", value: "010-2222-3333")
        XCTAssertEqual(CallCallerIdentity.resolve(texts: texts, contactName: { _ in nil }).phoneNumber, "+821022223333")
    }

    func testButtonOnlySnapshotsMissAStaticTextPhone() {
        let buttons = TestSnapshots.ringingCallBannerFixture()
        XCTAssertEqual(
            CallCallerIdentity.resolve(texts: CallCallerIdentity.texts(from: buttons), contactName: { _ in nil }).phoneNumber,
            "unknown"
        )
    }
}

final class CallAudioMixerTests: XCTestCase {
    func testMixAddsAndPadsTheShorterSide() {
        XCTAssertEqual(CallAudioMixer.mix(rx: [100, 200], tx: [50]), [150, 200])
    }

    func testInterleaveKeepsSidesOnSeparateChannels() {
        XCTAssertEqual(
            CallAudioMixer.interleave(rx: [1, 2, 3], tx: [10, 20]),
            [1, 10, 2, 20, 3, 0]
        )
    }

    func testConsumeTXFollowsRXClockAndLeavesRemainder() {
        var pending: [Int16] = [1, 2, 3, 4, 5]
        XCTAssertEqual(CallAudioMixer.consumeTX(&pending, count: 3), [1, 2, 3])
        XCTAssertEqual(pending, [4, 5])
        XCTAssertEqual(CallAudioMixer.consumeTX(&pending, count: 4), [4, 5, 0, 0])
        XCTAssertEqual(pending, [])
    }

    func testMixKeepsOverlappingSpeechOnTheSameSamples() {
        XCTAssertEqual(CallAudioMixer.mix(rx: [800, 100], tx: [900, 50]), [1700, 150])
    }

    func testConversationPlaysOneVoiceAtATimeAndKeepsOverlappingTX() {
        let rx: [Int16] = [0, 0, 800, 800, 0, 0]
        let tx: [Int16] = [900, 900, 900, 900, 900, 900]
        XCTAssertEqual(
            CallAudioMixer.conversation(rx: rx, tx: tx, window: 2, speechRMS: 200),
            [900, 900, 800, 800, 900, 900, 900, 900]
        )
    }

    func testConversationKeepsTurnOrderWithoutOverlap() {
        XCTAssertEqual(
            CallAudioMixer.conversation(rx: [800, 800, 0, 0], tx: [0, 0, 900, 900], window: 2, speechRMS: 200),
            [800, 800, 900, 900]
        )
    }

    func testAppendTXPadsToRXTimelineSoTurnsDoNotOverlap() {
        var tx: [Int16] = []
        CallAudioMixer.appendTX([10, 11], onto: &tx, timeline: 4)
        XCTAssertEqual(tx, [0, 0, 0, 0, 10, 11])
        CallAudioMixer.appendTX([20], onto: &tx, timeline: 10)
        XCTAssertEqual(tx, [0, 0, 0, 0, 10, 11, 0, 0, 0, 0, 20])
        XCTAssertEqual(
            CallAudioMixer.mix(rx: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], tx: tx),
            [1, 1, 1, 1, 11, 12, 1, 1, 1, 1, 21]
        )
    }
}
