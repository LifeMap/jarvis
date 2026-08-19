import Foundation

/// Phase 3 CHECKPOINT 1 — Active Call Audio Route Takeover & Safe Restore.
///
/// Device UIDs shared by every Phase 3 file that needs to identify the Phase 1 driver's two
/// devices. Mirrors `JarvisAudioDriverTool/DriverIdentifiers.swift` (a separate executable
/// target's constants) — kept as a small local copy here since `JarvisCallBridge` cannot depend on
/// that target, exactly the same duplication pattern `AudioDriverStatus.swift` already uses.
enum JarvisAudioDeviceUIDs {
    static let capture = "com.jarvis.callbridge.audio.capture"
    static let inject = "com.jarvis.callbridge.audio.inject"
    static let tap = "com.jarvis.callbridge.audio.tap"
}

/// A route snapshot identified by stable device **UID**, not display name or raw `AudioDeviceID`
/// (§10 — "prefer stable device UID for recovery/identity... do not use a human-readable device
/// name as the authoritative key"). Distinct from `AudioRouteSnapshot` (Phase 0's read-only
/// diagnostic snapshot, keyed by ID+name for UI display) — this one is `Codable` because it's the
/// thing a crash-recovery record persists.
struct CallAudioRouteSnapshot: Equatable, Codable {
    let inputUID: String
    let outputUID: String
    let systemOutputUID: String
}

/// Minimal crash-recovery record (§19) — written to disk *before* any route mutation, so a crash
/// mid-call-audio-takeover doesn't leave the Mac silently stuck on the virtual devices. Explicitly
/// NOT a database, NOT call-lifecycle state, NOT caller information — just enough to safely put
/// the user's original routes back.
struct CallAudioRecoveryRecord: Equatable, Codable {
    let version: Int
    let callSessionID: String
    let createdAt: Date
    let originalInputUID: String
    let originalOutputUID: String
    let originalSystemOutputUID: String
    let targetInputUID: String
    let targetOutputUID: String

    static let currentVersion = 1
}

/// Internal audio-session state — deliberately separate from `CallLifecycleState` (§7): call
/// lifecycle ("what is the phone call doing") and audio route lifecycle ("what have we done to
/// CoreAudio because of it") are different concerns with different failure modes.
enum CallAudioSessionState: String, Equatable {
    case idle = "Idle"
    case preparing = "Preparing"
    case routed = "Routed"
    case restoring = "Restoring"
    case failed = "Failed"
}
