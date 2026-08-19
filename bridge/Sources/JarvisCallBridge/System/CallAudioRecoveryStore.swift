import Foundation

/// Phase 3 §19 — a minimal, app-owned persistence mechanism for exactly one
/// `CallAudioRecoveryRecord`. Deliberately not a database, and deliberately never stores call
/// lifecycle state or caller information — see `CallAudioRecoveryRecord`'s own doc comment.
///
/// Real-device fix: `clear()` now returns whether the record is actually gone afterward — the
/// previous version silently swallowed `FileManager` errors (`try?`), so a failed deletion looked
/// identical to a successful one. `CallAudioSessionController` treats recovery-record removal as
/// a required rollback/restore postcondition (§9/§10), which needs a real answer here, not an
/// assumption.
protocol CallAudioRecoveryStore {
    func load() -> CallAudioRecoveryRecord?
    func save(_ record: CallAudioRecoveryRecord)
    @discardableResult func clear() -> Bool
}

/// Real implementation — one small JSON file under Application Support. Phase 2 intentionally had
/// no persistence at all (§19: "Phase 2 intentionally had no persistence... Phase 3 is different
/// because the app now mutates global macOS audio routes" — a crash while routes point at the
/// virtual devices could leave the Mac in an undesirable audio state without this).
struct FileCallAudioRecoveryStore: CallAudioRecoveryStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let directory = base.appendingPathComponent("com.jarvis.callbridge", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("call-audio-recovery.json")
        }
    }

    func load() -> CallAudioRecoveryRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CallAudioRecoveryRecord.self, from: data)
    }

    func save(_ record: CallAudioRecoveryRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    func clear() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true } // already absent
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }
}

/// Test double — no real file I/O, so unit tests never touch disk for this.
final class InMemoryCallAudioRecoveryStore: CallAudioRecoveryStore {
    var storedRecord: CallAudioRecoveryRecord?
    private(set) var saveCallCount = 0
    private(set) var clearCallCount = 0
    /// Test-only fault injection — when true, `clear()` reports failure (record stays present),
    /// simulating a real filesystem deletion failure so rollback/restore postcondition-tightening
    /// can be exercised without touching disk.
    var failClear = false

    func load() -> CallAudioRecoveryRecord? { storedRecord }

    func save(_ record: CallAudioRecoveryRecord) {
        storedRecord = record
        saveCallCount += 1
    }

    @discardableResult
    func clear() -> Bool {
        clearCallCount += 1
        guard !failClear else { return false }
        storedRecord = nil
        return true
    }
}
