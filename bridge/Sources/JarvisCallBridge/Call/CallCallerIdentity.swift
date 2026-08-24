import Foundation

struct CallCaller: Equatable {
    var name: String
    var phoneNumber: String

    static let unknown = CallCaller(name: "unknown", phoneNumber: "unknown")
}

enum CallCallerIdentity {
    static let knownControlLabels: Set<String> = [
        "응답", "거절", "답장", "더 보기", "종료", "소리 끔", "키패드", "FaceTime 영상 통화",
    ]

    static func resolve(texts: [String], contactName: (String) -> String?) -> CallCaller {
        let phone = phoneNumber(in: texts) ?? "unknown"
        if phone != "unknown", let saved = contactName(phone)?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return CallCaller(name: saved, phoneNumber: phone)
        }
        if let banner = bannerName(in: texts, excludingPhone: phone) {
            return CallCaller(name: banner, phoneNumber: phone)
        }
        return CallCaller(name: "unknown", phoneNumber: phone)
    }

    static func phoneNumber(in texts: [String]) -> String? {
        let pattern = #"(?:\+82[-.\s]?)?0?1[016789][-.\s]?\d{3,4}[-.\s]?\d{4}"#
        let regex = try? NSRegularExpression(pattern: pattern)
        for text in texts {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex?.firstMatch(in: text, range: range), let swift = Range(match.range, in: text) {
                return normalizePhone(String(text[swift]))
            }
        }
        return nil
    }

    static func bannerName(in texts: [String], excludingPhone phone: String) -> String? {
        let phoneDigits = digits(phone)
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !knownControlLabels.contains(trimmed) else { continue }
            if phoneDigits.count >= 8, digits(trimmed) == phoneDigits { continue }
            if phoneNumber(in: [trimmed]) != nil, bannerLetters(trimmed).isEmpty { continue }
            let letters = bannerLetters(trimmed)
            if !letters.isEmpty { return letters }
        }
        return nil
    }

    static func texts(from snapshots: [AXElementSnapshot]) -> [String] {
        snapshots.flatMap { snapshot in
            identityTexts(title: snapshot.title, description: snapshot.elementDescription, value: nil)
        }
    }

    static func identityTexts(title: String?, description: String?, value: String?) -> [String] {
        [title, description, value].compactMap { text in
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func normalizePhone(_ raw: String) -> String {
        let compact = raw.filter { $0.isNumber || $0 == "+" }
        if compact.hasPrefix("+") { return compact }
        if compact.hasPrefix("82"), compact.count >= 11 { return "+" + compact }
        if compact.hasPrefix("0"), compact.count >= 8 { return "+82" + String(compact.dropFirst()) }
        return compact
    }

    private static func digits(_ value: String) -> String {
        value.filter(\.isNumber)
    }

    private static func bannerLetters(_ value: String) -> String {
        let stripped = value.replacingOccurrences(of: #"[+\d\-.\s()]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped
    }
}

protocol CallCallerResolving: AnyObject {
    func resolve() -> CallCaller
}

final class StoredCallCallerResolver: CallCallerResolving {
    var texts: [String] = []
    var contactName: (String) -> String? = { _ in nil }

    func ingest(_ incoming: [String]) {
        for text in incoming where !texts.contains(text) {
            texts.append(text)
        }
    }

    func reset() {
        texts = []
    }

    func resolve() -> CallCaller {
        CallCallerIdentity.resolve(texts: texts, contactName: contactName)
    }
}
