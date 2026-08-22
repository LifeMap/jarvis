import Foundation

struct RealtimeEnvValues: Equatable {
    var apiKey: String?
    var model: String?
}

enum RealtimeEnvFile {
    static let defaultModel = "gpt-realtime-2.1-mini"

    static func envFileURL(appBundleURL: URL) -> URL {
        appBundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env")
    }

    static func load(from url: URL) -> RealtimeEnvValues {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return RealtimeEnvValues()
        }
        var values = RealtimeEnvValues()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "OPENAI_API_KEY":
                values.apiKey = value.isEmpty ? nil : value
            case "OPENAI_REALTIME_MODEL":
                values.model = value.isEmpty ? nil : value
            default:
                break
            }
        }
        return values
    }

    static func loadFromProcess(environment: [String: String] = ProcessInfo.processInfo.environment) -> RealtimeEnvValues {
        RealtimeEnvValues(
            apiKey: emptyToNil(environment["OPENAI_API_KEY"]),
            model: emptyToNil(environment["OPENAI_REALTIME_MODEL"])
        )
    }

    static func resolve(
        appBundleURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RealtimeEnvValues {
        let process = loadFromProcess(environment: environment)
        let file = load(from: envFileURL(appBundleURL: appBundleURL))
        return RealtimeEnvValues(
            apiKey: process.apiKey ?? file.apiKey,
            model: process.model ?? file.model ?? defaultModel
        )
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
