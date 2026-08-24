import Foundation

enum CallTelURL {
    static func make(phoneNumber: String) -> URL? {
        let compact = phoneNumber.filter { $0.isNumber || $0 == "+" }
        guard !compact.isEmpty, compact != "unknown" else { return nil }
        return URL(string: "tel:\(compact)")
    }
}
