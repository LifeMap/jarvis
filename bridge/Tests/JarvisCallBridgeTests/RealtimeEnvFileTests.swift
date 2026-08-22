import XCTest
@testable import JarvisCallBridge

final class RealtimeEnvFileTests: XCTestCase {
    func testMissingFileReturnsNilKey() {
        let url = URL(fileURLWithPath: "/tmp/jarvis-missing-\(UUID().uuidString).env")
        let loaded = RealtimeEnvFile.load(from: url)
        XCTAssertNil(loaded.apiKey)
        XCTAssertNil(loaded.model)
    }

    func testReadsKeyIgnoresCommentsAndBlankLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-env-\(UUID().uuidString)")
        try """
        # comment

        OPENAI_API_KEY=sk-test
        OPENAI_REALTIME_MODEL=gpt-realtime-2.1-mini
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = RealtimeEnvFile.load(from: url)
        XCTAssertEqual(loaded.apiKey, "sk-test")
        XCTAssertEqual(loaded.model, "gpt-realtime-2.1-mini")
    }

    func testStripsQuotesAndRejectsEmptyKey() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-env-\(UUID().uuidString)")
        try "OPENAI_API_KEY=\"\"\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(RealtimeEnvFile.load(from: url).apiKey)
    }

    func testStripsSurroundingQuotes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-env-\(UUID().uuidString)")
        try "OPENAI_API_KEY=\"sk-quoted\"\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(RealtimeEnvFile.load(from: url).apiKey, "sk-quoted")
    }

    func testAppBundleResolvesBridgeDotEnv() {
        let app = URL(fileURLWithPath: "/Volumes/Dev/workspaces/twms/jarvis/bridge/.build/Jarvis Call Bridge.app")
        let env = RealtimeEnvFile.envFileURL(appBundleURL: app)
        XCTAssertEqual(env.path, "/Volumes/Dev/workspaces/twms/jarvis/bridge/.env")
    }
}
