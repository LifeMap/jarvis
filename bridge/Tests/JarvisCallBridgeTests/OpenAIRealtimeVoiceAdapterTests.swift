import XCTest
@testable import JarvisCallBridge

@MainActor
final class OpenAIRealtimeVoiceAdapterTests: XCTestCase {
    func testConnectSendsSessionUpdateWithInstructionsAndPCMFormat() async throws {
        let transport = FakeRealtimeWebSocketTransport()
        let adapter = OpenAIRealtimeVoiceAdapter(
            apiKey: "sk-test",
            model: "gpt-realtime-2.1-mini",
            transport: transport
        )
        let connected = await adapter.connect()
        XCTAssertTrue(connected)
        XCTAssertEqual(transport.connectedURL?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
        XCTAssertEqual(transport.connectedHeaders["Authorization"], "Bearer sk-test")
        let first = transport.sentTexts.first ?? ""
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "session.update")
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["instructions"] as? String, OpenAIRealtimeVoiceAdapter.defaultInstructions)
        let encoded = String(data: try JSONSerialization.data(withJSONObject: session), encoding: .utf8) ?? ""
        XCTAssertTrue(encoded.contains("24000") || encoded.contains("pcm16"))
        await adapter.disconnect()
    }

    func testSendRXAppendsBase64PCM16() async {
        let transport = FakeRealtimeWebSocketTransport()
        let adapter = OpenAIRealtimeVoiceAdapter(apiKey: "sk-test", model: "m", transport: transport)
        let connected = await adapter.connect()
        XCTAssertTrue(connected)
        adapter.sendRX([1, -2, 3])
        for _ in 0..<20 { await Task.yield() }
        let last = transport.sentTexts.last ?? ""
        XCTAssertTrue(last.contains("input_audio_buffer.append"))
        let payload = pcm16Base64([1, -2, 3])
        XCTAssertTrue(last.contains(payload))
        await adapter.disconnect()
    }

    func testPollTXDecodesOutputAudioDelta() async {
        let transport = FakeRealtimeWebSocketTransport()
        let adapter = OpenAIRealtimeVoiceAdapter(apiKey: "sk-test", model: "m", transport: transport)
        let connected = await adapter.connect()
        XCTAssertTrue(connected)
        adapter.ingestServerMessage("""
        {"type":"response.output_audio.delta","delta":"\(pcm16Base64([10, 20]))"}
        """)
        XCTAssertEqual(adapter.pollTX(), [10, 20])
        adapter.ingestServerMessage("""
        {"type":"response.audio.delta","delta":"\(pcm16Base64([30]))"}
        """)
        XCTAssertEqual(adapter.pollTX(), [30])
        XCTAssertEqual(adapter.pollTX(), [])
        await adapter.disconnect()
    }

    func testConnectFailureReturnsFalse() async {
        let transport = FakeRealtimeWebSocketTransport()
        transport.connectError = URLError(.notConnectedToInternet)
        let adapter = OpenAIRealtimeVoiceAdapter(apiKey: "sk-test", model: "m", transport: transport)
        let connected = await adapter.connect()
        XCTAssertFalse(connected)
        XCTAssertTrue(transport.sentTexts.isEmpty)
    }
}

private func pcm16Base64(_ samples: [Int16]) -> String {
    var little = samples.map { $0.littleEndian }
    return little.withUnsafeBytes { Data($0).base64EncodedString() }
}
