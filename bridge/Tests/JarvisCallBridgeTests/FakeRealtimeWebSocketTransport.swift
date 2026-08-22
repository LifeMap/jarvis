import Foundation
@testable import JarvisCallBridge

final class FakeRealtimeWebSocketTransport: RealtimeWebSocketTransporting, @unchecked Sendable {
    var connectError: Error?
    private(set) var connectedURL: URL?
    private(set) var connectedHeaders: [String: String] = [:]
    private(set) var sentTexts: [String] = []
    private var incoming: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var closed = false

    func connect(url: URL, headers: [String: String]) async throws {
        if let connectError { throw connectError }
        connectedURL = url
        connectedHeaders = headers
        closed = false
    }

    func send(text: String) async throws {
        sentTexts.append(text)
    }

    func receive() async throws -> String {
        if !incoming.isEmpty {
            return incoming.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            if closed {
                continuation.resume(throwing: RealtimeWebSocketTransportError.closed)
            } else {
                waiters.append(continuation)
            }
        }
    }

    func close() {
        closed = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(throwing: RealtimeWebSocketTransportError.closed) }
    }

    func push(_ text: String) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: text)
        } else {
            incoming.append(text)
        }
    }
}
