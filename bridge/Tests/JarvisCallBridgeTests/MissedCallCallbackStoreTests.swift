import XCTest
@testable import JarvisCallBridge

final class MissedCallCallbackStoreTests: XCTestCase {
    private func store() -> UserDefaultsMissedCallCallbackStore {
        let defaults = UserDefaults(suiteName: "test.callback.\(UUID().uuidString)")!
        return UserDefaultsMissedCallCallbackStore(defaults: defaults)
    }

    func testEnqueueDedupsByPhoneAndKeepsOldest() {
        let store = store()
        let first = Date(timeIntervalSince1970: 100)
        store.enqueue(phoneNumber: "+821011111111", ringingStartedAt: first)
        store.enqueue(phoneNumber: "+821011111111", ringingStartedAt: Date(timeIntervalSince1970: 200))
        store.enqueue(phoneNumber: "+821022222222", ringingStartedAt: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.peekOldest()?.phoneNumber, "+821011111111")
        XCTAssertEqual(store.peekOldest()?.ringingStartedAt, first)
    }

    func testPopOldestRemovesOne() {
        let store = store()
        store.enqueue(phoneNumber: "010-1111-1111", ringingStartedAt: Date(timeIntervalSince1970: 1))
        store.enqueue(phoneNumber: "010-2222-2222", ringingStartedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(store.popOldest()?.phoneNumber, "010-1111-1111")
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.peekOldest()?.phoneNumber, "010-2222-2222")
    }

    func testSettingsClamp() {
        let store = store()
        XCTAssertEqual(store.intervalMinutes, 5)
        XCTAssertEqual(store.noAnswerSeconds, 45)
        store.intervalMinutes = 0
        store.noAnswerSeconds = 3
        XCTAssertEqual(store.intervalMinutes, 1)
        XCTAssertEqual(store.noAnswerSeconds, 15)
        store.intervalMinutes = 99
        store.noAnswerSeconds = 200
        XCTAssertEqual(store.intervalMinutes, 60)
        XCTAssertEqual(store.noAnswerSeconds, 120)
    }
}
