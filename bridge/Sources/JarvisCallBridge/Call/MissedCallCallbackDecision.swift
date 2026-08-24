import Foundation

struct MissedCallCallbackInput: Equatable {
    var workModeOn: Bool
    var autoAnswerOn: Bool
    var reachedActive: Bool
    var ringingDuration: TimeInterval
    var delaySeconds: TimeInterval
    var phoneNumber: String
}

enum MissedCallCallbackDecision: Equatable {
    case enqueue(phoneNumber: String)
    case reportNoNumber
    case skip

    static func evaluate(_ input: MissedCallCallbackInput) -> MissedCallCallbackDecision {
        guard input.workModeOn, input.autoAnswerOn, !input.reachedActive else { return .skip }
        guard input.ringingDuration >= input.delaySeconds else { return .skip }
        if input.phoneNumber == "unknown" || input.phoneNumber.isEmpty { return .reportNoNumber }
        return .enqueue(phoneNumber: input.phoneNumber)
    }
}
