import Foundation

/// Mutes Continuity call playback (`avconferenced`) so the original speaker (e.g. M80C) stays
/// usable by other apps. Hogging that speaker would evict Zoom/YouTube too.
@MainActor
protocol CallAudioProcessMuteControlling: AnyObject {
    var isMuting: Bool { get }
    @discardableResult
    func startMuting(bundleIDs: [String]) -> Bool
    func stopMuting()
}

enum CallAudioProcessMutePolicy {
    static let continuityOutputBundleIDs = ["com.apple.avconferenced"]
    static let forbiddenBundleIDs: Set<String> = [
        "com.apple.mediaserverd",
        "com.apple.audio.coreaudiod",
        "com.apple.coreaudiod",
    ]

    static func sanitized(_ bundleIDs: [String]) -> [String] {
        bundleIDs.filter { !forbiddenBundleIDs.contains($0) }
    }
}

@MainActor
final class NullCallAudioProcessMuteController: CallAudioProcessMuteControlling {
    private(set) var isMuting = false

    func startMuting(bundleIDs: [String]) -> Bool {
        guard !CallAudioProcessMutePolicy.sanitized(bundleIDs).isEmpty else { return false }
        isMuting = true
        return true
    }

    func stopMuting() {
        isMuting = false
    }
}
