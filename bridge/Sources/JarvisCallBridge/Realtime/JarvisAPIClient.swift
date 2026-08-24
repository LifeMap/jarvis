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

@MainActor
final class JarvisAPIClient: JarvisRealtimeCredentialMinting {
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
}
