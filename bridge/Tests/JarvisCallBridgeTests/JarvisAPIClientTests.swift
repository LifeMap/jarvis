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
