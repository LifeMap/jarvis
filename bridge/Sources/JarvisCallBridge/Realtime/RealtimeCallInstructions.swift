import Foundation

enum RealtimeSpeechStyle: String, CaseIterable, Identifiable {
    case polite
    case casual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .polite: return "존댓말"
        case .casual: return "반말"
        }
    }

    static func parse(_ raw: String?) -> RealtimeSpeechStyle {
        RealtimeSpeechStyle(rawValue: raw ?? "") ?? .polite
    }
}

enum RealtimeCallInstructions {
    static let extraLimit = 2000
    static let politeLine = "항상 존댓말로만 말하세요. 반말을 쓰지 마세요."
    static let casualLine = "항상 반말로만 말하세요. 존댓말을 쓰지 마세요."
    static let verbatimOpeningLine = "통화가 연결되면 상대가 한 마디도 하기 전에, 아래 첫 인사를 한 글자도 바꾸지 말고 그대로 말하세요. 의역·요약·추가는 하지 마세요."
    static let openingOnceLine = "이 인사는 통화 시작 시 딱 한 번만 하세요. 상대가 여보세요라고 하거나 말을 이어가면 인사를 다시 하지 말고 용건만 들으세요."
    static let alreadyGreetedLine = "이미 첫 인사를 했습니다. 인사를 반복하지 마세요. 상대가 여보세요라고 해도 인사하지 말고, 용건을 듣고 짧게 답하세요."
    static let defaultOpening = "안녕하세요, 저는 AI개인 비서 자비스입니다. 지금 통화 연결이 어려워서 제가 받았어요. 말씀 해 주시면 제가 전달 하겠습니다"
    static let styleKey = "jarvis.realtime.speechStyle"
    static let extraKey = "jarvis.realtime.extraInstructions"
    static let incomingKey = "jarvis.realtime.incomingGreeting"
    static let outgoingKey = "jarvis.realtime.outgoingGreeting"

    static func compose(style: RealtimeSpeechStyle, extra: String) -> String {
        let styleLine = style == .polite ? politeLine : casualLine
        let opening = normalizedExtra(extra).isEmpty ? defaultOpening : normalizedExtra(extra)
        return [
            OpenAIRealtimeVoiceAdapter.defaultInstructions,
            styleLine,
            verbatimOpeningLine,
            openingOnceLine,
            opening,
        ].joined(separator: "\n")
    }

    static func composeOutgoing(style: RealtimeSpeechStyle, extra: String) -> String {
        let styleLine = style == .polite ? politeLine : casualLine
        let greeting = normalizedExtra(extra)
        if greeting.isEmpty {
            return [OpenAIRealtimeVoiceAdapter.defaultInstructions, styleLine].joined(separator: "\n")
        }
        return [
            OpenAIRealtimeVoiceAdapter.defaultInstructions,
            styleLine,
            verbatimOpeningLine,
            openingOnceLine,
            greeting,
        ].joined(separator: "\n")
    }

    static func composeAfterOpening(style: RealtimeSpeechStyle) -> String {
        let styleLine = style == .polite ? politeLine : casualLine
        return [
            OpenAIRealtimeVoiceAdapter.defaultInstructions,
            styleLine,
            alreadyGreetedLine,
        ].joined(separator: "\n")
    }

    static func normalizedExtra(_ extra: String) -> String {
        let trimmed = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= extraLimit { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: extraLimit)
        return String(trimmed[..<end])
    }

    static func connectLog(style: RealtimeSpeechStyle, extra: String) -> String {
        let extraFlag = normalizedExtra(extra).isEmpty ? "empty" : "set"
        return "[CALL] realtime instructions style=\(style.rawValue) extra=\(extraFlag)"
    }
}

final class UserDefaultsRealtimeCallInstructionStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var speechStyle: RealtimeSpeechStyle {
        get { RealtimeSpeechStyle.parse(defaults.string(forKey: RealtimeCallInstructions.styleKey)) }
        set { defaults.set(newValue.rawValue, forKey: RealtimeCallInstructions.styleKey) }
    }

    var incomingGreeting: String {
        get {
            let incoming = RealtimeCallInstructions.normalizedExtra(defaults.string(forKey: RealtimeCallInstructions.incomingKey) ?? "")
            if !incoming.isEmpty { return incoming }
            return RealtimeCallInstructions.normalizedExtra(defaults.string(forKey: RealtimeCallInstructions.extraKey) ?? "")
        }
        set { defaults.set(RealtimeCallInstructions.normalizedExtra(newValue), forKey: RealtimeCallInstructions.incomingKey) }
    }

    var outgoingGreeting: String {
        get { RealtimeCallInstructions.normalizedExtra(defaults.string(forKey: RealtimeCallInstructions.outgoingKey) ?? "") }
        set { defaults.set(RealtimeCallInstructions.normalizedExtra(newValue), forKey: RealtimeCallInstructions.outgoingKey) }
    }

    var extraInstructions: String {
        get { incomingGreeting }
        set { incomingGreeting = newValue }
    }

    func composedInstructions(direction: CallReportDirection = .incoming) -> String {
        switch direction {
        case .incoming:
            return RealtimeCallInstructions.compose(style: speechStyle, extra: incomingGreeting)
        case .outgoing:
            return RealtimeCallInstructions.composeOutgoing(style: speechStyle, extra: outgoingGreeting)
        }
    }
}
