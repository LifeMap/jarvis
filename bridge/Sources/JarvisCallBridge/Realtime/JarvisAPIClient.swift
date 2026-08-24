import Foundation

struct JarvisRealtimeClientSecret: Equatable {
    var value: String
    var expiresAt: Int
    var model: String
}

enum JarvisAPIClientError: Error, Equatable {
    case jarvisAuth
    case network
}

@MainActor
protocol JarvisRealtimeCredentialMinting: AnyObject {
    func mintRealtimeClientSecret(origin: String, token: String, model: String) async throws -> JarvisRealtimeClientSecret
}

enum CallReportDirection: String {
    case incoming
    case outgoing
}

@MainActor
protocol JarvisCallReporting: AnyObject {
    func createCall(
        origin: String,
        token: String,
        caller: CallCaller,
        startedAt: Date,
        direction: CallReportDirection
    ) async throws -> String
    func uploadCallAudio(origin: String, token: String, id: String, data: Data) async throws
    func completeCall(
        origin: String,
        token: String,
        id: String,
        endedAt: Date,
        transcript: [CallTranscriptTurn],
        uploadFailed: Bool,
        summary: String?
    ) async throws
}

@MainActor
final class JarvisAPIClient: JarvisRealtimeCredentialMinting, JarvisCallReporting {
    typealias Exchange = (URLRequest) async throws -> (Data, URLResponse)

    private let exchange: Exchange

    init(exchange: @escaping Exchange = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.exchange = exchange
    }

    func mintRealtimeClientSecret(origin: String, token: String, model: String) async throws -> JarvisRealtimeClientSecret {
        let trimmed = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        guard let url = URL(string: trimmed + "/api/realtime/client-secret") else {
            throw JarvisAPIClientError.network
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await exchange(request)
        } catch {
            throw JarvisAPIClientError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            throw JarvisAPIClientError.jarvisAuth
        }
        guard status == 200 else {
            throw JarvisAPIClientError.network
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["value"] as? String, !value.isEmpty
        else {
            throw JarvisAPIClientError.network
        }
        let expiresAt = (object["expiresAt"] as? Int)
            ?? (object["expiresAt"] as? NSNumber)?.intValue
            ?? 0
        let mintedModel = (object["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? model
        return JarvisRealtimeClientSecret(value: value, expiresAt: expiresAt, model: mintedModel)
    }

    func createCall(
        origin: String,
        token: String,
        caller: CallCaller,
        startedAt: Date,
        direction: CallReportDirection
    ) async throws -> String {
        let object = try await jsonRequest(
            origin: origin,
            token: token,
            path: "/api/calls",
            method: "POST",
            body: [
                "caller": ["name": caller.name, "phoneNumber": caller.phoneNumber],
                "startedAt": Self.iso8601.string(from: startedAt),
                "direction": direction.rawValue,
            ]
        )
        guard let id = object["id"] as? String, !id.isEmpty else { throw JarvisAPIClientError.network }
        return id
    }

    func uploadCallAudio(origin: String, token: String, id: String, data: Data) async throws {
        let trimmed = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        guard let url = URL(string: trimmed + "/api/calls/\(id)/audio") else { throw JarvisAPIClientError.network }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let response: URLResponse
        do {
            (_, response) = try await exchange(request)
        } catch {
            throw JarvisAPIClientError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw JarvisAPIClientError.jarvisAuth }
        guard status == 200 else { throw JarvisAPIClientError.network }
    }

    func completeCall(
        origin: String,
        token: String,
        id: String,
        endedAt: Date,
        transcript: [CallTranscriptTurn],
        uploadFailed: Bool,
        summary: String?
    ) async throws {
        var body: [String: Any] = [
            "endedAt": Self.iso8601.string(from: endedAt),
            "transcript": transcript.map { ["role": $0.role, "text": $0.text] },
            "uploadFailed": uploadFailed,
        ]
        if let summary {
            body["summary"] = summary
        }
        _ = try await jsonRequest(
            origin: origin,
            token: token,
            path: "/api/calls/\(id)/complete",
            method: "POST",
            body: body
        )
    }

    private func jsonRequest(
        origin: String,
        token: String,
        path: String,
        method: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        let trimmed = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        guard let url = URL(string: trimmed + path) else { throw JarvisAPIClientError.network }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await exchange(request)
        } catch {
            throw JarvisAPIClientError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw JarvisAPIClientError.jarvisAuth }
        guard status == 200 else { throw JarvisAPIClientError.network }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JarvisAPIClientError.network
        }
        return object
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
