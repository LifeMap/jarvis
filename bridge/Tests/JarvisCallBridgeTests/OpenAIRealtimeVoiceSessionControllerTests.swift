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

    func testMissingJarvisAuthFailsWithoutAdapterConnect() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        let mock = MockRealtimeVoiceAdapter()
        let session = makeSession(pcm: pcm, adapter: mock, enabled: true, token: nil, origin: nil)
        await session.connect(reason: "takeover")
        XCTAssertEqual(mock.connectCount, 0)
        XCTAssertEqual(session.uiState, .failed("jarvis auth"))
        XCTAssertTrue(pcm.isRunning)
    }

    func testMintAuthFailureDoesNotConnectAdapter() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        let mock = MockRealtimeVoiceAdapter()
        let mint = FakeJarvisCredentialMint()
        mint.error = .jarvisAuth
        let session = makeSession(pcm: pcm, adapter: mock, mint: mint, enabled: true)
        await session.connect(reason: "takeover")
        XCTAssertEqual(mint.callCount, 1)
        XCTAssertEqual(mock.connectCount, 0)
        XCTAssertEqual(session.uiState, .failed("jarvis auth"))
        XCTAssertTrue(pcm.isRunning)
    }

    func testMintFailureDoesNotStopPCM() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        let mock = MockRealtimeVoiceAdapter()
        let mint = FakeJarvisCredentialMint()
        mint.error = .network
        let session = makeSession(pcm: pcm, adapter: mock, mint: mint, enabled: true)
        await session.connect(reason: "takeover")
        XCTAssertEqual(mock.connectCount, 0)
        XCTAssertEqual(session.uiState, .failed("network"))
        XCTAssertTrue(pcm.isRunning)
    }

    func testConnectMintsSecretBeforeAdapterConnect() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        let mock = MockRealtimeVoiceAdapter()
        let mint = FakeJarvisCredentialMint()
        mint.secret = JarvisRealtimeClientSecret(value: "ek_session", expiresAt: 1, model: "gpt-realtime-2.1-mini")
        var mintedKey: String?
        let session = OpenAIRealtimeVoiceSessionController(
            pcm: pcm,
            loadEnv: {
                RealtimeEnvValues(
                    model: "gpt-realtime-2.1-mini",
                    jarvisAPIToken: "jarvis-token",
                    jarvisAPIOrigin: "https://jarvis-api.twms.ai"
                )
            },
            mintCredentials: mint,
            makeAdapter: { env in
                mintedKey = env.apiKey
                return mock
            },
            documentsDirectory: FileManager.default.temporaryDirectory
        )
        session.isEnabled = true
        await session.connect(reason: "takeover")
        XCTAssertEqual(mint.callCount, 1)
        XCTAssertEqual(mint.lastOrigin, "https://jarvis-api.twms.ai")
        XCTAssertEqual(mint.lastToken, "jarvis-token")
        XCTAssertEqual(mintedKey, "ek_session")
        XCTAssertEqual(mock.connectCount, 1)
        XCTAssertEqual(session.uiState, .connected)
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

    func testInMemoryClearTXDropsQueuedFramesOnly() {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.rx = [0.1, 0.1]
        pcm.tx = [0.2, 0.2, 0.3, 0.3]
        pcm.clearTX()
        XCTAssertEqual(pcm.tx, [])
        XCTAssertEqual(pcm.rx, [0.1, 0.1])
        XCTAssertEqual(pcm.queuedTXFrames(), 0)
    }

    func testRemoteSpeechStartedClearsTXAndLeavesRXAndPCMRunning() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        pcm.rx = [0.4, 0.4]
        pcm.tx = [0.9, 0.9]
        let mock = MockRealtimeVoiceAdapter()
        mock.enqueueTX([100, 101])
        let session = makeSession(pcm: pcm, adapter: mock, enabled: true)
        await session.connect(reason: "takeover")
        mock.fireRemoteSpeechStarted()
        XCTAssertEqual(pcm.clearTXCount, 1)
        XCTAssertEqual(pcm.clearRXCount, 0)
        XCTAssertEqual(pcm.tx, [])
        XCTAssertEqual(pcm.rx, [0.4, 0.4])
        XCTAssertTrue(pcm.isRunning)
        XCTAssertEqual(mock.pollTX(), [])
        XCTAssertEqual(session.uiState, .connected)
    }

    private func makeSession(
        pcm: InMemoryRealtimePCMBuffer,
        adapter: MockRealtimeVoiceAdapter,
        mint: FakeJarvisCredentialMint = FakeJarvisCredentialMint(),
        enabled: Bool,
        token: String? = "jarvis-token",
        origin: String? = "https://jarvis-api.twms.ai"
    ) -> OpenAIRealtimeVoiceSessionController {
        let session = OpenAIRealtimeVoiceSessionController(
            pcm: pcm,
            loadEnv: {
                RealtimeEnvValues(
                    model: "gpt-realtime-2.1-mini",
                    jarvisAPIToken: token,
                    jarvisAPIOrigin: origin
                )
            },
            mintCredentials: mint,
            makeAdapter: { _ in adapter },
            documentsDirectory: FileManager.default.temporaryDirectory
        )
        session.isEnabled = enabled
        return session
    }
}

@MainActor
final class FakeJarvisCredentialMint: JarvisRealtimeCredentialMinting {
    var secret = JarvisRealtimeClientSecret(value: "ek_test", expiresAt: 1, model: "gpt-realtime-2.1-mini")
    var error: JarvisAPIClientError?
    private(set) var callCount = 0
    private(set) var lastOrigin: String?
    private(set) var lastToken: String?

    func mintRealtimeClientSecret(origin: String, token: String, model: String) async throws -> JarvisRealtimeClientSecret {
        callCount += 1
        lastOrigin = origin
        lastToken = token
        if let error { throw error }
        return secret
    }
}

@MainActor
final class InMemoryRealtimePCMBuffer: RealtimePCMBuffering {
    var isRunning = false
    var rx: [Float] = []
    var tx: [Float] = []
    private(set) var clearRXCount = 0
    private(set) var clearTXCount = 0

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

    func clearRX() {
        clearRXCount += 1
        rx = []
    }

    func clearTX() {
        clearTXCount += 1
        tx = []
    }
}
