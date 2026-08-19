import CoreAudio
import Foundation

/// Phase 3 CHECKPOINT 2 — CoreAudio Direct I/O + Deterministic RX/TX PCM Validation.
///
/// Deliberately separate from `CallLifecycleState` (what the phone call is doing) and
/// `CallAudioSessionState` (whether Jarvis owns the macOS default route) — this only describes
/// whether Bridge's own CoreAudio Direct I/O (Capture RX + Inject TX) is actually running.
enum CallAudioPCMState: String, Equatable {
    case idle = "Idle"
    case starting = "Starting"
    case running = "Running"
    case stopping = "Stopping"
    case failed = "Failed"
}

/// §16/§48 — the 1 kHz diagnostic tone never auto-plays; this is purely a UI/diagnostic mirror of
/// whether one is currently queued/playing.
enum CallAudioTestToneState: String, Equatable {
    case idle = "Idle"
    case queued = "Queued"
    case playing = "Playing"
}

/// §13 — diagnostic, never semantic: no VAD, no speech detection, no turn-taking. `rxRMSDBFS`/
/// `rxPeakDBFS` reflect only the single most recently completed RX callback's buffer (not a long
/// rolling average) — simple, deterministic, and sufficient to prove "real PCM is arriving and
/// visibly reacts to the remote signal."
struct CallAudioPCMMetrics: Equatable {
    var rxFrames: Int64 = 0
    var rxCallbacks: Int64 = 0
    var rxRMSDBFS: Float = CallAudioPCMMetrics.silenceFloorDBFS
    var rxPeakDBFS: Float = CallAudioPCMMetrics.silenceFloorDBFS
    var rxActive: Bool = false
    var txFrames: Int64 = 0
    var txCallbacks: Int64 = 0
    var txUnderrunCount: Int64 = 0

    /// dBFS floor used both as the "nothing observed yet" default and as the clamp for
    /// `20*log10(0)` (which is `-inf`) — keeps the value always finite and displayable.
    static let silenceFloorDBFS: Float = -96
    /// §13 — a simple, documented activity threshold for the diagnostic "Active/Silence" label
    /// only. Not a VAD, not used for any control-flow decision.
    static let activityThresholdDBFS: Float = -50

    static let zero = CallAudioPCMMetrics()
}

/// §11 — the actual native ASBD read from the driver at PCM-start time, not assumed. Compared
/// against the Phase 1 contract (48 kHz / Float32 / stereo / interleaved) before any I/O opens.
struct CallAudioPCMFormat: Equatable, CustomStringConvertible {
    let sampleRate: Double
    let channelCount: Int
    let bytesPerFrame: UInt32
    let isFloat: Bool
    let isInterleaved: Bool

    var description: String { "\(Int(sampleRate))Hz \(isFloat ? "Float32" : "Int") \(channelCount)ch \(isInterleaved ? "interleaved" : "non-interleaved")" }

    /// The one contract CHECKPOINT 2 is written against (§6/§11) — Phase 1's driver always
    /// advertises this exact format (`FillStreamFormat` in `PlugInInterface.c`). No resampling
    /// path exists; a mismatch is a hard failure, not something silently converted around.
    static let expected = CallAudioPCMFormat(sampleRate: 48000, channelCount: 2, bytesPerFrame: 8, isFloat: true, isInterleaved: true)
}

/// §7 — Bridge's own CoreAudio stream I/O, kept strictly separate from route/recovery logic
/// (`CallAudioSessionController` owns that). Injectable so tests can exercise start/stop
/// ordering, failure unwinding, and metrics without ever touching real CoreAudio devices (§40).
@MainActor
protocol CallAudioPCMControlling: AnyObject {
    /// §21 — must only be called once route verification has already passed. Resolves current
    /// Capture/Inject `AudioDeviceID`s fresh (§10), validates their native stream format (§11),
    /// creates CoreAudio Direct I/O, and starts Capture RX + Inject TX. On ANY failure, unwinds
    /// only what was actually started (§51) and returns to `.idle` — never left half-started.
    @discardableResult func start(reason: String) async -> Bool
    /// §22 — idempotent; safe to call when already `.idle`. Must fully stop and dispose I/O
    /// resources before returning, so the caller can safely proceed to route restoration
    /// immediately afterward.
    func stop(reason: String) async
    /// §15/§16 — queues the fixed deterministic 1 kHz tone into the already-running TX path.
    /// No-op (logged) if PCM isn't `.running`, or if a tone is already `.playing` (§48 — "reject
    /// while already playing" is the policy chosen here: simplest, safest, fully deterministic).
    func sendTestTone()
}
