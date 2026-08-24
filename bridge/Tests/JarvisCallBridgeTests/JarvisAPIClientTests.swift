import XCTest
@testable import JarvisCallBridge

@MainActor
final class JarvisAPIClientTests: XCTestCase {
    func testMintPostsBearerAndDecodesSecret() async throws {
        let client = JarvisAPIClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://jarvis-api.twms.ai/api/realtime/client-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jarvis-token")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "gpt-realtime-2.1-mini")
            let data = Data(#"{"value":"ek_live","expiresAt":1700000000,"model":"gpt-realtime-2.1-mini"}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        let secret = try await client.mintRealtimeClientSecret(
            origin: "https://jarvis-api.twms.ai",
            token: "jarvis-token",
            model: "gpt-realtime-2.1-mini"
        )
        XCTAssertEqual(secret, JarvisRealtimeClientSecret(value: "ek_live", expiresAt: 1_700_000_000, model: "gpt-realtime-2.1-mini"))
    }

    func testMint401IsJarvisAuth() async {
        let client = JarvisAPIClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }
        do {
            _ = try await client.mintRealtimeClientSecret(origin: "https://example.test", token: "bad", model: "m")
            XCTFail("expected auth failure")
        } catch {
            XCTAssertEqual(error as? JarvisAPIClientError, .jarvisAuth)
        }
    }

    func testCreateCallPostsCallerAndReturnsId() async throws {
        let client = JarvisAPIClient { request in
            XCTAssertEqual(request.url?.path, "/api/calls")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let caller = body?["caller"] as? [String: String]
            XCTAssertEqual(caller?["name"], "unknown")
            XCTAssertEqual(caller?["phoneNumber"], "+821011122233")
            XCTAssertEqual(body?["direction"] as? String, "incoming")
            let data = Data(#"{"id":"call-1","status":"active"}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let id = try await client.createCall(
            origin: "https://jarvis-api.twms.ai",
            token: "jarvis-token",
            caller: CallCaller(name: "unknown", phoneNumber: "+821011122233"),
            startedAt: Date(timeIntervalSince1970: 1),
            direction: .incoming
        )
        XCTAssertEqual(id, "call-1")
    }

    func testCreateCallPostsOutgoingDirection() async throws {
        let client = JarvisAPIClient { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(body?["direction"] as? String, "outgoing")
            let data = Data(#"{"id":"call-out","status":"active"}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let id = try await client.createCall(
            origin: "https://jarvis-api.twms.ai",
            token: "jarvis-token",
            caller: CallCaller(name: "unknown", phoneNumber: "+821011122233"),
            startedAt: Date(timeIntervalSince1970: 1),
            direction: .outgoing
        )
        XCTAssertEqual(id, "call-out")
    }

    func testCompleteCallPostsFixedSummary() async throws {
        let client = JarvisAPIClient { request in
            XCTAssertEqual(request.url?.path, "/api/calls/call-1/complete")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            XCTAssertEqual(body?["summary"] as? String, "콜백 연결 안 됨")
            XCTAssertEqual(body?["uploadFailed"] as? Bool, true)
            let transcript = body?["transcript"] as? [Any]
            XCTAssertEqual(transcript?.count, 0)
            return (Data(#"{"id":"call-1","status":"failed"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await client.completeCall(
            origin: "https://jarvis-api.twms.ai",
            token: "t",
            id: "call-1",
            endedAt: Date(timeIntervalSince1970: 2),
            transcript: [],
            uploadFailed: true,
            summary: "콜백 연결 안 됨"
        )
    }

    func testMintTransportErrorIsNetwork() async {
        let client = JarvisAPIClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await client.mintRealtimeClientSecret(origin: "https://example.test", token: "t", model: "m")
            XCTFail("expected network failure")
        } catch {
            XCTAssertEqual(error as? JarvisAPIClientError, .network)
        }
    }
}
