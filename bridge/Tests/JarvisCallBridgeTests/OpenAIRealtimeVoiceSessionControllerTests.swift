import XCTest
@testable import JarvisCallBridge

@MainActor
final class OpenAIRealtimeVoiceSessionControllerTests: XCTestCase {
    func testToggleOffDoesNotConnectAdapter() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        let mock = MockRealtimeVoiceAdapter()
        let session = makeSession(pcm: pcm, adapter: mock, enabled: false)
        await session.connect(reason: "takeover")
        XCTAssertEqual(mock.connectCount, 0)
        XCTAssertEqual(session.uiState, .idle)
    }

    func testToggleOnWithPCMConnects() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        let mock = MockRealtimeVoiceAdapter()
        let session = makeSession(pcm: pcm, adapter: mock, enabled: true)
        await session.connect(reason: "takeover")
        XCTAssertEqual(mock.connectCount, 1)
        XCTAssertEqual(session.uiState, .connected)
    }

    func testMissingKeyFailsWithoutAdapterConnect() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        let mock = MockRealtimeVoiceAdapter()
        let session = makeSession(pcm: pcm, adapter: mock, enabled: true, apiKey: nil)
        await session.connect(reason: "takeover")
        XCTAssertEqual(mock.connectCount, 0)
        XCTAssertEqual(session.uiState, .failed("missing API key"))
        XCTAssertTrue(pcm.isRunning)
    }

    func testAdapterFailureDoesNotStopPCM() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        let mock = MockRealtimeVoiceAdapter()
        mock.failConnect = true
        let session = makeSession(pcm: pcm, adapter: mock, enabled: true)
        await session.connect(reason: "takeover")
        XCTAssertEqual(session.uiState, .failed("network"))
        XCTAssertTrue(pcm.isRunning)
    }

    func testDisconnectLeavesPCMRunning() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        let mock = MockRealtimeVoiceAdapter()
        let session = makeSession(pcm: pcm, adapter: mock, enabled: true)
        await session.connect(reason: "takeover")
        await session.disconnect(reason: "toggle-off")
        XCTAssertEqual(mock.disconnectCount, 1)
        XCTAssertTrue(pcm.isRunning)
        XCTAssertEqual(session.uiState, .armed)
    }

    func testPumpSendsConvertedRXAndWatermarksTX() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        pcm.rx = [Float](repeating: 0.2, count: 8)
        let mock = MockRealtimeVoiceAdapter()
        mock.enqueueTX([1000, 2000, 3000, 4000])
        let session = makeSession(pcm: pcm, adapter: mock, enabled: true)
        await session.connect(reason: "takeover")
        session.pumpOnce()
        XCTAssertEqual(mock.sentRX.count, 1)
        XCTAssertFalse(mock.sentRX[0].isEmpty)
        XCTAssertGreaterThan(pcm.tx.count, 0)
        XCTAssertLessThanOrEqual(pcm.queuedTXFrames(), OpenAIRealtimeVoiceSessionController.txWatermarkFrames)
    }

    private func makeSession(
        pcm: InMemoryRealtimePCMBuffer,
        adapter: MockRealtimeVoiceAdapter,
        enabled: Bool,
        apiKey: String? = "sk-test"
    ) -> OpenAIRealtimeVoiceSessionController {
        let session = OpenAIRealtimeVoiceSessionController(
            pcm: pcm,
            loadEnv: { RealtimeEnvValues(apiKey: apiKey, model: "gpt-realtime-2.1-mini") },
            makeAdapter: { _ in adapter },
            documentsDirectory: FileManager.default.temporaryDirectory
        )
        session.isEnabled = enabled
        return session
    }
}

@MainActor
final class InMemoryRealtimePCMBuffer: RealtimePCMBuffering {
    var isRunning = false
    var rx: [Float] = []
    var tx: [Float] = []

    func readRXFrames(maxFrames: Int) -> [Float] {
        let take = min(maxFrames * 2, rx.count)
        let out = Array(rx.prefix(take))
        rx.removeFirst(take)
        return out
    }

    func writeTXFrames(_ interleavedStereo: [Float]) -> Int {
        tx.append(contentsOf: interleavedStereo)
        return interleavedStereo.count / 2
    }

    func queuedTXFrames() -> Int { tx.count / 2 }

    func clearRX() { rx = [] }
}
