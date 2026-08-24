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

    func testConnectStartsPumpBeforeCreateCallReturns() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        pcm.rx = Array(repeating: 0.1, count: 9600)
        let mock = MockRealtimeVoiceAdapter()
        mock.enqueueTX([7, 8])
        let reporter = FakeCallReporter()
        reporter.blockCreate = true
        let session = OpenAIRealtimeVoiceSessionController(
            pcm: pcm,
            loadEnv: {
                RealtimeEnvValues(
                    model: "gpt-realtime-2.1-mini",
                    jarvisAPIToken: "jarvis-token",
                    jarvisAPIOrigin: "https://jarvis-api.twms.ai"
                )
            },
            mintCredentials: FakeJarvisCredentialMint(),
            callReporter: reporter,
            makeAdapter: { _ in mock },
            documentsDirectory: FileManager.default.temporaryDirectory
        )
        session.isEnabled = true
        await session.connect(reason: "takeover")
        XCTAssertEqual(session.uiState, .connected)
        session.pumpOnce()
        XCTAssertGreaterThan(pcm.tx.count, 0)
        XCTAssertNil(reporter.createdCaller)
        reporter.unblockCreate()
        for _ in 0..<100 where reporter.createdCaller == nil {
            await Task.yield()
        }
        XCTAssertEqual(reporter.createdCaller?.phoneNumber, "unknown")
    }

    func testPrepareConnectsAdapterWithoutPCMOrPump() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = false
        let mock = MockRealtimeVoiceAdapter()
        mock.enqueueTX([1, 2])
        let mint = FakeJarvisCredentialMint()
        let session = makeSession(pcm: pcm, adapter: mock, mint: mint, enabled: true)
        await session.prepare(reason: "ringing")
        XCTAssertEqual(mint.callCount, 1)
        XCTAssertEqual(mock.connectCount, 1)
        session.pumpOnce()
        XCTAssertEqual(pcm.tx, [])
        pcm.isRunning = true
        await session.connect(reason: "takeover")
        XCTAssertEqual(mint.callCount, 1)
        XCTAssertEqual(mock.connectCount, 1)
        XCTAssertEqual(session.uiState, .connected)
    }

    func testConnectCreatesCallAndDisconnectUploadsReport() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        pcm.rx = Array(repeating: 0.1, count: 9600)
        let mock = MockRealtimeVoiceAdapter()
        mock.transcript = [CallTranscriptTurn(role: "caller", text: "안녕하세요")]
        mock.enqueueTX([9, 8])
        let reporter = FakeCallReporter()
        let session = OpenAIRealtimeVoiceSessionController(
            pcm: pcm,
            loadEnv: {
                RealtimeEnvValues(
                    model: "gpt-realtime-2.1-mini",
                    jarvisAPIToken: "jarvis-token",
                    jarvisAPIOrigin: "https://jarvis-api.twms.ai"
                )
            },
            mintCredentials: FakeJarvisCredentialMint(),
            callReporter: reporter,
            resolveCaller: { CallCaller(name: "unknown", phoneNumber: "01011112222") },
            encoder: IdentityCallAudioEncoder(),
            makeAdapter: { _ in mock },
            documentsDirectory: FileManager.default.temporaryDirectory
        )
        session.isEnabled = true
        await session.connect(reason: "takeover")
        session.pumpOnce()
        await session.disconnect(reason: "call-ended")
        XCTAssertEqual(reporter.uploadedIDs, [])
        await session.finalizeIdleReport()
        XCTAssertEqual(reporter.createdCaller, CallCaller(name: "unknown", phoneNumber: "01011112222"))
        XCTAssertEqual(reporter.uploadedIDs, ["call-report"])
        XCTAssertEqual(reporter.completedIDs, ["call-report"])
        XCTAssertEqual(reporter.lastTranscript, [CallTranscriptTurn(role: "caller", text: "안녕하세요")])
        XCTAssertFalse(reporter.lastUploadFailed ?? true)
        XCTAssertTrue(pcm.isRunning)
    }

    func testPumpWritesCombinedMixWAVAlongsideRXandTX() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mix-wav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        pcm.rx = Array(repeating: 0.2, count: 9600)
        let mock = MockRealtimeVoiceAdapter()
        mock.enqueueTX([300, 301, 302])
        let wired = OpenAIRealtimeVoiceSessionController(
            pcm: pcm,
            loadEnv: {
                RealtimeEnvValues(
                    model: "gpt-realtime-2.1-mini",
                    jarvisAPIToken: "jarvis-token",
                    jarvisAPIOrigin: "https://jarvis-api.twms.ai"
                )
            },
            mintCredentials: FakeJarvisCredentialMint(),
            makeAdapter: { _ in mock },
            documentsDirectory: directory
        )
        wired.isEnabled = true
        await wired.connect(reason: "takeover")
        wired.pumpOnce()
        await wired.disconnect(reason: "call-ended")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertTrue(names.contains { $0.hasPrefix("jarvis-call-bridge-rx-") })
        XCTAssertTrue(names.contains { $0.hasPrefix("jarvis-call-bridge-tx-") })
        XCTAssertTrue(names.contains { $0.hasPrefix("jarvis-call-bridge-mix-") })
        let mix = try XCTUnwrap(names.first { $0.hasPrefix("jarvis-call-bridge-mix-") })
        let rxName = try XCTUnwrap(names.first { $0.hasPrefix("jarvis-call-bridge-rx-") })
        let txName = try XCTUnwrap(names.first { $0.hasPrefix("jarvis-call-bridge-tx-") })
        let mixData = try Data(contentsOf: directory.appendingPathComponent(mix))
        let rxData = try Data(contentsOf: directory.appendingPathComponent(rxName))
        let txData = try Data(contentsOf: directory.appendingPathComponent(txName))
        XCTAssertEqual(mixData.count, rxData.count)
        XCTAssertEqual(txData.count, rxData.count)
        XCTAssertGreaterThan(mixData.count, 44)
    }

    func testHangupDropsLeftoverTXInsteadOfExtendingTheRecording() async throws {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        pcm.rx = Array(repeating: 0.1, count: 9600)
        let mock = MockRealtimeVoiceAdapter()
        mock.enqueueTX(Array(repeating: 1200, count: 20_000))
        let reporter = FakeCallReporter()
        let session = OpenAIRealtimeVoiceSessionController(
            pcm: pcm,
            loadEnv: {
                RealtimeEnvValues(
                    model: "gpt-realtime-2.1-mini",
                    jarvisAPIToken: "jarvis-token",
                    jarvisAPIOrigin: "https://jarvis-api.twms.ai"
                )
            },
            mintCredentials: FakeJarvisCredentialMint(),
            callReporter: reporter,
            encoder: IdentityCallAudioEncoder(),
            makeAdapter: { _ in mock },
            documentsDirectory: FileManager.default.temporaryDirectory
        )
        session.isEnabled = true
        await session.connect(reason: "takeover")
        session.pumpOnce()
        mock.enqueueTX(Array(repeating: 2200, count: 8_000))
        session.pumpOnce()
        await session.stopRecording()
        pcm.rx = Array(repeating: 0.4, count: 9600)
        mock.enqueueTX(Array(repeating: 3000, count: 4_000))
        session.pumpOnce()
        await session.disconnect(reason: "call-ended")
        await session.finalizeIdleReport()
        let uploaded = try XCTUnwrap(reporter.lastUploadedData)
        let firstRX = RealtimeAudioConverter.toProviderRX(interleavedStereo48k: Array(repeating: 0.1, count: 9600))
        XCTAssertEqual(uploaded.count, firstRX.count * 2)
        XCTAssertFalse(reporter.lastUploadFailed ?? true)
    }

    func testDisconnectReturnsBeforeUploadCompletes() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        pcm.rx = Array(repeating: 0.1, count: 9600)
        let mock = MockRealtimeVoiceAdapter()
        mock.enqueueTX([9, 8])
        let reporter = FakeCallReporter()
        reporter.blockUpload = true
        let session = OpenAIRealtimeVoiceSessionController(
            pcm: pcm,
            loadEnv: {
                RealtimeEnvValues(
                    model: "gpt-realtime-2.1-mini",
                    jarvisAPIToken: "jarvis-token",
                    jarvisAPIOrigin: "https://jarvis-api.twms.ai"
                )
            },
            mintCredentials: FakeJarvisCredentialMint(),
            callReporter: reporter,
            encoder: IdentityCallAudioEncoder(),
            makeAdapter: { _ in mock },
            documentsDirectory: FileManager.default.temporaryDirectory
        )
        session.isEnabled = true
        await session.connect(reason: "takeover")
        session.pumpOnce()
        await session.disconnect(reason: "call-ended")
        XCTAssertEqual(reporter.uploadedIDs, [])
        XCTAssertEqual(session.uiState, .armed)
        XCTAssertTrue(pcm.isRunning)
        reporter.unblockUpload()
        await session.finalizeIdleReport()
        XCTAssertEqual(reporter.uploadedIDs, ["call-report"])
    }

    func testCreateCallFailureDoesNotStopPCM() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        let mock = MockRealtimeVoiceAdapter()
        let reporter = FakeCallReporter()
        reporter.createError = .network
        let wired = OpenAIRealtimeVoiceSessionController(
            pcm: pcm,
            loadEnv: {
                RealtimeEnvValues(jarvisAPIToken: "t", jarvisAPIOrigin: "https://jarvis-api.twms.ai")
            },
            mintCredentials: FakeJarvisCredentialMint(),
            callReporter: reporter,
            makeAdapter: { _ in mock },
            documentsDirectory: FileManager.default.temporaryDirectory
        )
        wired.isEnabled = true
        await wired.connect(reason: "takeover")
        XCTAssertEqual(wired.uiState, .connected)
        XCTAssertTrue(pcm.isRunning)
        await wired.disconnect(reason: "call-ended")
        XCTAssertTrue(reporter.uploadedIDs.isEmpty)
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

    func testPumpKeepsTXWhenHALWriteIsPartial() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        pcm.maxWriteFrames = 100
        let mock = MockRealtimeVoiceAdapter()
        mock.enqueueTX([Int16](repeating: 1200, count: 8000))
        let session = makeSession(pcm: pcm, adapter: mock, enabled: true)
        await session.connect(reason: "takeover")
        for _ in 0..<30 {
            session.pumpOnce()
        }
        XCTAssertGreaterThan(pcm.totalWrittenFrames, 1500)
    }

    func testPumpKeepsTXThatDoesNotFitTheWatermark() async {
        let pcm = InMemoryRealtimePCMBuffer()
        pcm.isRunning = true
        pcm.tx = [Float](repeating: 0.01, count: (OpenAIRealtimeVoiceSessionController.txWatermarkFrames - 8) * 2)
        let mock = MockRealtimeVoiceAdapter()
        mock.enqueueTX([Int16](repeating: 1200, count: 8000))
        let session = makeSession(pcm: pcm, adapter: mock, enabled: true)
        await session.connect(reason: "takeover")
        session.pumpOnce()
        XCTAssertLessThanOrEqual(pcm.queuedTXFrames(), OpenAIRealtimeVoiceSessionController.txWatermarkFrames)
        XCTAssertEqual(mock.pollTX(), [])
        pcm.tx = Array(pcm.tx.suffix(80))
        XCTAssertEqual(pcm.queuedTXFrames(), 40)
        session.pumpOnce()
        XCTAssertGreaterThan(pcm.queuedTXFrames(), 40)
        XCTAssertLessThanOrEqual(pcm.queuedTXFrames(), OpenAIRealtimeVoiceSessionController.txWatermarkFrames)
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
        mock.enqueueTX([200, 201])
        pcm.rx = [Float](repeating: 0.2, count: 8)
        session.pumpOnce()
        XCTAssertEqual(pcm.tx, [])
        XCTAssertEqual(mock.pollTX(), [])
        mock.fireRemoteSpeechStopped()
        mock.enqueueTX([300, 301])
        session.pumpOnce()
        XCTAssertGreaterThan(pcm.tx.count, 0)
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
final class FakeCallReporter: JarvisCallReporting {
    var createError: JarvisAPIClientError?
    var blockUpload = false
    private var uploadResume: CheckedContinuation<Void, Never>?
    private(set) var createdCaller: CallCaller?
    private(set) var uploadedIDs: [String] = []
    private(set) var completedIDs: [String] = []
    private(set) var lastTranscript: [CallTranscriptTurn] = []
    private(set) var lastUploadFailed: Bool?
    private(set) var lastUploadedData: Data?

    var blockCreate = false
    private var createResume: CheckedContinuation<Void, Never>?

    var createdDirection: CallReportDirection?
    var lastSummary: String?

    func createCall(origin: String, token: String, caller: CallCaller, startedAt: Date, direction: CallReportDirection) async throws -> String {
        if let createError { throw createError }
        if blockCreate {
            await withCheckedContinuation { createResume = $0 }
        }
        createdCaller = caller
        createdDirection = direction
        return "call-report"
    }

    func unblockCreate() {
        createResume?.resume()
        createResume = nil
        blockCreate = false
    }

    func uploadCallAudio(origin: String, token: String, id: String, data: Data) async throws {
        if blockUpload {
            await withCheckedContinuation { uploadResume = $0 }
        }
        lastUploadedData = data
        uploadedIDs.append(id)
    }

    func unblockUpload() {
        uploadResume?.resume()
        uploadResume = nil
        blockUpload = false
    }

    func completeCall(origin: String, token: String, id: String, endedAt: Date, transcript: [CallTranscriptTurn], uploadFailed: Bool, summary: String?) async throws {
        completedIDs.append(id)
        lastTranscript = transcript
        lastUploadFailed = uploadFailed
        lastSummary = summary
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
    var maxWriteFrames: Int?
    private(set) var totalWrittenFrames = 0
    private(set) var clearRXCount = 0
    private(set) var clearTXCount = 0

    func readRXFrames(maxFrames: Int) -> [Float] {
        let take = min(maxFrames * 2, rx.count)
        let out = Array(rx.prefix(take))
        rx.removeFirst(take)
        return out
    }

    func writeTXFrames(_ interleavedStereo: [Float]) -> Int {
        let frames = interleavedStereo.count / 2
        let take = min(frames, maxWriteFrames ?? frames)
        tx.append(contentsOf: interleavedStereo.prefix(take * 2))
        totalWrittenFrames += take
        return take
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
