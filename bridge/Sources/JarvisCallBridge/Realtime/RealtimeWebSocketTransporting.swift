import Foundation

protocol RealtimeWebSocketTransporting: AnyObject, Sendable {
    func connect(url: URL, headers: [String: String]) async throws
    func send(text: String) async throws
    func receive() async throws -> String
    func close()
}

enum RealtimeWebSocketTransportError: Error {
    case notConnected
    case closed
}

final class URLSessionRealtimeWebSocketTransport: RealtimeWebSocketTransporting, @unchecked Sendable {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(url: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(text: String) async throws {
        guard let task else { throw RealtimeWebSocketTransportError.notConnected }
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        guard let task else { throw RealtimeWebSocketTransportError.notConnected }
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return ""
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
