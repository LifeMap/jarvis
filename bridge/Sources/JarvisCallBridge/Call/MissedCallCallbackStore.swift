import Foundation

struct MissedCallCallbackItem: Codable, Equatable {
    var phoneNumber: String
    var ringingStartedAt: Date
}

protocol MissedCallCallbackStoring: AnyObject {
    var intervalMinutes: Int { get set }
    var noAnswerSeconds: Int { get set }
    var count: Int { get }
    func enqueue(phoneNumber: String, ringingStartedAt: Date)
    func peekOldest() -> MissedCallCallbackItem?
    func popOldest() -> MissedCallCallbackItem?
}

final class UserDefaultsMissedCallCallbackStore: MissedCallCallbackStoring {
    static let queueKey = "jarvis.callback.queue"
    static let intervalKey = "jarvis.callback.intervalMinutes"
    static let noAnswerKey = "jarvis.callback.noAnswerSeconds"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var intervalMinutes: Int {
        get { clamped(defaults.object(forKey: Self.intervalKey) as? Int ?? 5, 1, 60) }
        set { defaults.set(clamped(newValue, 1, 60), forKey: Self.intervalKey) }
    }

    var noAnswerSeconds: Int {
        get { clamped(defaults.object(forKey: Self.noAnswerKey) as? Int ?? 45, 15, 120) }
        set { defaults.set(clamped(newValue, 15, 120), forKey: Self.noAnswerKey) }
    }

    var count: Int { items().count }

    func enqueue(phoneNumber: String, ringingStartedAt: Date) {
        var current = items()
        if current.contains(where: { $0.phoneNumber == phoneNumber }) { return }
        current.append(MissedCallCallbackItem(phoneNumber: phoneNumber, ringingStartedAt: ringingStartedAt))
        save(current)
    }

    func peekOldest() -> MissedCallCallbackItem? {
        items().min(by: { $0.ringingStartedAt < $1.ringingStartedAt })
    }

    func popOldest() -> MissedCallCallbackItem? {
        var current = items()
        guard let oldest = current.min(by: { $0.ringingStartedAt < $1.ringingStartedAt }) else { return nil }
        current.removeAll { $0.phoneNumber == oldest.phoneNumber && $0.ringingStartedAt == oldest.ringingStartedAt }
        save(current)
        return oldest
    }

    private func items() -> [MissedCallCallbackItem] {
        guard let data = defaults.data(forKey: Self.queueKey) else { return [] }
        return (try? JSONDecoder().decode([MissedCallCallbackItem].self, from: data)) ?? []
    }

    private func save(_ items: [MissedCallCallbackItem]) {
        defaults.set(try? JSONEncoder().encode(items), forKey: Self.queueKey)
    }

    private func clamped(_ value: Int, _ minValue: Int, _ maxValue: Int) -> Int {
        min(maxValue, max(minValue, value))
    }
}
