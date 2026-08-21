import Foundation

/// Phase 3 CHECKPOINT 1 — Active Call Audio Route Takeover & Safe Restore.
///
/// Owns the audio-route side of a call. On `.ringing` it activates Capture/Inject, takes
/// Default Output (Capture) so Phone.app writes caller PCM there, takes Default Input (Inject)
/// so Jarvis can talk, and mutes Continuity playback (`avconferenced`) so remote voice does not
/// also leak onto the original speaker. Other apps duck for the call — that is an OS limit.
/// PCM starts only once that same session is `.active`. Idle Work Mode must **not** seize the
/// Mac's audio. Hangup restores the original input/output and stops mute, even if Work Mode
/// stays ON. Restore also happens on Work Mode OFF, app quit, or route-ownership loss.
/// Deliberately
/// separate from `CallLifecycleTracker` (§7). A session that appears as `.active` without a
/// prior ringing takeover still falls back to Active-time acquisition.
///
/// Driven from the same poll cycle `IncomingCallObserver.tick()` already runs (see
/// `handleLifecycleChange`, called once per tick right after `CallLifecycleTracker.update()`) —
/// consistent with the "candidates and evidence come from the same cycle" principle from
/// CHECKPOINT 3's Production/Focused parity fix. No independent timers of its own beyond the
/// bounded route-convergence poll below.
///
/// Real-device fix (route verification settling): a first CHECKPOINT 1 real-device test showed
/// the Default Output/Input setters and the very next readback landing in the *same millisecond*,
/// with the readback still reporting the pre-change device — CoreAudio's default-device property
/// change is not guaranteed synchronously observable immediately after
/// `AudioObjectSetPropertyData` returns success. `waitForRouteConvergence` replaces every
/// immediate single readback (forward takeover, rollback, normal restore) with a short bounded
/// poll that returns the moment the target is actually observed.
@MainActor
final class CallAudioSessionController: ObservableObject {
    @Published private(set) var state: CallAudioSessionState = .idle
    @Published private(set) var routeOwnerSessionID: String?
    /// UI/diagnostic-only mirror of whether a recovery record is currently persisted. Always set
    /// from a fresh `recoveryStore.load()` right after any save/clear attempt — never a cached
    /// assumption of what the store operation "should" have done (a first real-device test showed
    /// exactly that kind of stale-boolean risk is worth guarding against explicitly).
    @Published private(set) var hasPersistedRecoveryRecord: Bool

    /// UI synchronization fix: fires once at the end of every transactional boundary that may have
    /// actually mutated the real CoreAudio default route (or, for startup recovery, may have
    /// mutated it in a *previous* process run) — successful takeover, restore, rollback, ownership
    /// loss, and startup recovery. Deliberately a plain closure, not a reference to
    /// `BridgeViewModel`/any SwiftUI type — this controller stays fully decoupled from
    /// presentation; the caller decides what "refresh" means (`BridgeViewModel.refreshRouteSnapshot`
    /// re-reads the real CoreAudio route via `AudioRouteReading`, never fabricates a value from
    /// `state`). The `String` argument is the same "reason" vocabulary already used in
    /// `[CALL-AUDIO]` logs (`"takeover"`, `"rollback"`, `"ownership-loss"`, `"startup-recovery"`, or
    /// whatever `restore(reason:)` was itself invoked with, e.g. `"work-mode-off"`/`"app-quit"`).
    var onRouteMutated: ((String) -> Void)?

    private let routeController: CallAudioRouteControlling
    private let deviceActivator: JarvisAudioDeviceActivating
    private let recoveryStore: CallAudioRecoveryStore
    private let logger: BridgeLogger
    /// Phase 3 CHECKPOINT 2 — Bridge's own CoreAudio Direct I/O (Capture RX + Inject TX), owned
    /// and coordinated from here so §21/§22's start/stop ordering (PCM only after route
    /// verification PASS; PCM fully stopped before any route restoration/device deactivation) is
    /// explicit in code, not dependent on UI observation timing. `CallAudioSessionController`
    /// stays "route ownership/recovery/restore"; `pcmController` stays "CoreAudio stream I/O
    /// only" — this class is purely the coordinator between the two.
    let pcmController: CallAudioPCMControlling
    private let realtimeSession: RealtimeVoiceSessionControlling
    private let processMute: CallAudioProcessMuteControlling

    /// Convergence polling bounds — real-device evidence showed settling happens well under this;
    /// conservative bound stays inside the ~1s ceiling §5 asks for and under the 750ms poll tick
    /// most of the time so a single takeover doesn't routinely spill into the next tick.
    private let convergenceMaxAttempts: Int
    private let convergencePollNanoseconds: UInt64

    private var originalSnapshot: CallAudioRouteSnapshot?
    /// True only after a successful `pcmController.start` for the current route ownership.
    /// Cleared on every stop path (restore / rollback / ownership-loss) so a later session can
    /// start PCM again. Separate from `state == .routed` because ringing takeover reaches
    /// `.routed` without opening I/O.
    private var pcmStarted = false
    /// Sessions that must never be (re)routed again — either a takeover already failed for them
    /// (§13: "fail closed for that call session", never retried on every poll tick), or the user
    /// took route ownership back mid-call (§18) and re-grabbing it on the very next tick would be
    /// exactly the "tug-of-war" that section explicitly forbids. Never cleared — session ids are
    /// ephemeral per-call UUIDs, so this stays small for the life of one app run.
    private var excludedSessionIDs: Set<String> = []

    init(
        routeController: CallAudioRouteControlling? = nil,
        deviceActivator: JarvisAudioDeviceActivating? = nil,
        recoveryStore: CallAudioRecoveryStore = FileCallAudioRecoveryStore(),
        pcmController: CallAudioPCMControlling? = nil,
        realtimeSession: RealtimeVoiceSessionControlling? = nil,
        processMute: CallAudioProcessMuteControlling? = nil,
        logger: BridgeLogger,
        convergenceMaxAttempts: Int = 10,
        convergencePollNanoseconds: UInt64 = 75_000_000
    ) {
        // Defaults are constructed here (rather than as parameter default expressions, which
        // can't reference another parameter) so the real CoreAudio implementations share this
        // controller's own logger — their `[CALL-AUDIO-COREAUDIO]`/`[CALL-AUDIO-DEVICE]` lines
        // interleave with `[CALL-AUDIO]` in the same UI log instead of going to a detached logger
        // no one reads.
        self.routeController = routeController ?? SystemCallAudioRouteController(logger: logger)
        self.deviceActivator = deviceActivator ?? SystemJarvisAudioDeviceActivator(logger: logger)
        self.recoveryStore = recoveryStore
        self.pcmController = pcmController ?? SystemCallAudioPCMController(logger: logger)
        self.realtimeSession = realtimeSession ?? NullRealtimeVoiceSessionController()
        self.processMute = processMute ?? NullCallAudioProcessMuteController()
        self.logger = logger
        self.convergenceMaxAttempts = convergenceMaxAttempts
        self.convergencePollNanoseconds = convergencePollNanoseconds
        self.hasPersistedRecoveryRecord = recoveryStore.load() != nil
    }

    /// Called once per `IncomingCallObserver` poll tick (§9's trigger conditions are evaluated
    /// here) — never on a separate timer beyond the bounded convergence poll inside a takeover.
    func handleLifecycleChange(callState: CallLifecycleState, session: CallSession?, workModeArmed: Bool) async {
        if state == .routed, let owner = routeOwnerSessionID, let lostOwnershipSnapshot = lostRouteOwnershipSnapshot() {
            // §31 investigation — expected vs. observed UIDs are the exact, definitive reason
            // this fired (hasLostRouteOwnership is UID-based, never AudioObjectID-based — see
            // §32 note on that function). AudioObjectIDs are deliberately not logged here:
            // CallAudioRouteSnapshot is UID-only by design (the same reason ownership comparison
            // itself never touches an AudioObjectID), and the UID mismatch alone already fully
            // explains the decision.
            logger.log("[CALL-AUDIO] route-ownership-lost session=\(owner) expectedInputUID=\(JarvisAudioDeviceUIDs.inject) observedInputUID=\(lostOwnershipSnapshot.inputUID) expectedOutputUID=\(JarvisAudioDeviceUIDs.capture) leftOutputUID=\(originalSnapshot?.outputUID ?? "nil") observedOutputUID=\(lostOwnershipSnapshot.outputUID)")
            // §22 of CHECKPOINT 2: PCM must be fully stopped before any device deactivation —
            // the user just took the route back, so Bridge's own I/O against Capture/Inject must
            // not still be running underneath them.
            await realtimeSession.disconnect(reason: "ownership-loss")
            await pcmController.stop(reason: "ownership-loss")
            pcmStarted = false
            stopContinuityOutputMute()
            // §18: don't fight the user — drop our own devices and give up on this session's
            // route ownership without forcing anything back.
            deviceActivator.setInjectActive(false)
            deviceActivator.setCaptureActive(false)
            clearRecoveryRecord()
            excludedSessionIDs.insert(owner)
            originalSnapshot = nil
            routeOwnerSessionID = nil
            state = .idle
            onRouteMutated?("ownership-loss")
            return
        }

        guard workModeArmed else {
            if routeOwnerSessionID != nil { await restore(reason: "work-mode-off") }
            return
        }

        switch callState {
        case .ringing:
            // Capture/Inject + Continuity mute. Idle Work Mode must not seize audio.
            guard let session else { return }
            await attemptRouteTakeoverIfNeeded(session: session)

        case .active:
            guard let session else { return }
            await attemptRouteTakeoverIfNeeded(session: session)
            await startPCMIfNeeded(session: session)

        case .idle, .ended:
            if routeOwnerSessionID != nil { await restore(reason: "call-ended") }

        case .answering, .ending, .unknown:
            break
        }
    }

    /// §16 — immediate safety restore for conditions that don't go through the normal
    /// lifecycle-driven path: Work Mode OFF/Bridge disabled already flow through
    /// `handleLifecycleChange`'s `workModeArmed` guard above, so this is for app shutdown.
    func emergencyRestore(reason: String) async {
        guard routeOwnerSessionID != nil else { return }
        await restore(reason: reason)
    }

    /// §19-21 — run once at app launch, before Work Mode auto-arms. Never mutates System Output
    /// (there is no method on `CallAudioRouteControlling` that could). No convergence polling
    /// needed here — whatever route mutation produced the recovery record happened in a *previous*
    /// process run and has long since settled by the time this one launches.
    func performStartupRecovery() {
        guard let record = recoveryStore.load() else { return }
        defer { onRouteMutated?("startup-recovery") }
        logger.log("[CALL-AUDIO] startup recovery detected")

        guard let current = routeController.currentRouteSnapshot() else {
            logger.log("[CALL-AUDIO] startup recovery result=failed-no-current-route")
            clearRecoveryRecord()
            return
        }

        let currentlyOnJarvisRoute = current.outputUID == record.targetOutputUID || current.inputUID == record.targetInputUID
        guard currentlyOnJarvisRoute else {
            // Case B (§20): stale record, but the user (or a previous clean run) already has
            // non-Jarvis routes — never overwrite whatever they're using now.
            releaseHogIfPresent(uid: record.originalOutputUID)
            logger.log("[CALL-AUDIO] startup recovery result=stale-record-cleared")
            clearRecoveryRecord()
            return
        }

        guard routeController.deviceExists(uid: record.originalOutputUID), routeController.deviceExists(uid: record.originalInputUID) else {
            // Case C (§20): don't guess a replacement device — just stop forcing the virtual ones.
            logger.log("[CALL-AUDIO] startup recovery result=original-device-missing")
            releaseHogIfPresent(uid: record.originalOutputUID)
            deviceActivator.setInjectActive(false)
            deviceActivator.setCaptureActive(false)
            clearRecoveryRecord()
            return
        }

        // Case A (§20): restore the recorded original routes.
        releaseHogIfPresent(uid: record.originalOutputUID)
        let outputOK = routeController.setDefaultOutputDevice(uid: record.originalOutputUID)
        let inputOK = routeController.setDefaultInputDevice(uid: record.originalInputUID)
        deviceActivator.setInjectActive(false)
        deviceActivator.setCaptureActive(false)
        logger.log("[CALL-AUDIO] startup recovery result=\(outputOK && inputOK ? "restored" : "partial-failure")")
        clearRecoveryRecord()
    }

    // MARK: - Takeover (§12/§13)

    private func attemptTakeover(ownerID: String) async {
        state = .preparing
        logger.log("[CALL-AUDIO] prepare session=\(ownerID)")

        guard routeController.deviceExists(uid: JarvisAudioDeviceUIDs.capture), routeController.deviceExists(uid: JarvisAudioDeviceUIDs.inject), routeController.deviceExists(uid: JarvisAudioDeviceUIDs.tap) else {
            fail(ownerID: ownerID, stage: "device-missing")
            return
        }

        guard let snapshot = routeController.currentRouteSnapshot() else {
            fail(ownerID: ownerID, stage: "snapshot")
            return
        }
        logger.log("[CALL-AUDIO] snapshot inputUID=\(snapshot.inputUID) outputUID=\(snapshot.outputUID) systemOutputUID=\(snapshot.systemOutputUID)")

        let record = CallAudioRecoveryRecord(
            version: CallAudioRecoveryRecord.currentVersion, callSessionID: ownerID, createdAt: Date(),
            originalInputUID: snapshot.inputUID, originalOutputUID: snapshot.outputUID, originalSystemOutputUID: snapshot.systemOutputUID,
            targetInputUID: JarvisAudioDeviceUIDs.inject, targetOutputUID: JarvisAudioDeviceUIDs.capture
        )
        saveRecoveryRecord(record)

        guard deviceActivator.setCaptureActive(true) else {
            await rollback(to: snapshot, ownerID: ownerID, stage: "capture-activate", activatedCapture: false, activatedInject: false)
            return
        }
        logger.log("[CALL-AUDIO] driver capture activated")

        guard deviceActivator.setInjectActive(true) else {
            await rollback(to: snapshot, ownerID: ownerID, stage: "inject-activate", activatedCapture: true, activatedInject: false)
            return
        }
        logger.log("[CALL-AUDIO] driver inject activated")

        guard routeController.setDefaultOutputDevice(uid: JarvisAudioDeviceUIDs.capture) else {
            await rollback(to: snapshot, ownerID: ownerID, stage: "output-route", activatedCapture: true, activatedInject: true)
            return
        }
        logger.log("[CALL-AUDIO] default-output -> capture")

        guard routeController.setDefaultInputDevice(uid: JarvisAudioDeviceUIDs.inject) else {
            await rollback(to: snapshot, ownerID: ownerID, stage: "input-route", activatedCapture: true, activatedInject: true)
            return
        }
        logger.log("[CALL-AUDIO] default-input -> inject")

        logger.log("[CALL-AUDIO] route verification waiting session=\(ownerID)")
        let target = CallAudioRouteSnapshot(inputUID: JarvisAudioDeviceUIDs.inject, outputUID: JarvisAudioDeviceUIDs.capture, systemOutputUID: snapshot.systemOutputUID)
        let convergence = await waitForRouteConvergence(target: target)
        guard convergence.converged else {
            logger.log("[CALL-AUDIO] route verification timeout attempts=\(convergence.attempts) elapsedMs=\(convergence.elapsedMs) inputMatch=\(convergence.inputMatch) outputMatch=\(convergence.outputMatch) systemOutputMatch=\(convergence.systemOutputMatch) \(convergence.timeoutLogSuffix) session=\(ownerID)")
            await rollback(to: snapshot, ownerID: ownerID, stage: "verification", activatedCapture: true, activatedInject: true)
            return
        }
        logger.log("[CALL-AUDIO] route verification pass attempts=\(convergence.attempts) elapsedMs=\(convergence.elapsedMs) session=\(ownerID)")

        originalSnapshot = snapshot
        routeOwnerSessionID = ownerID
        state = .routed
        startContinuityOutputMute()
        logger.log("[CALL-AUDIO] state=routed session=\(ownerID)")
        onRouteMutated?("takeover")
        // PCM is started separately from `.active` via `startPCMIfNeeded` — ringing takeover
        // must not open Bridge I/O (v1 regression: audio too early can hide native ringing).
    }

    private func attemptRouteTakeoverIfNeeded(session: CallSession) async {
        guard !excludedSessionIDs.contains(session.id) else { return }
        guard routeOwnerSessionID != session.id else { return } // already owns — idempotent
        guard state == .idle else { return } // never re-attempt mid-preparing/routed/restoring
        await attemptTakeover(ownerID: session.id)
    }

    /// §21 of CHECKPOINT 2: PCM may only start after route verification has already passed and
    /// `state == .routed`, and only for a verified `.active` session. §25: if it fails to start,
    /// this is NOT a state we may leave the call routed into Jarvis's virtual devices with no
    /// functioning PCM runtime — `rollback` emergency-restores the route, deactivates the
    /// devices, and excludes this session from retry.
    private func startPCMIfNeeded(session: CallSession) async {
        guard !excludedSessionIDs.contains(session.id) else { return }
        guard routeOwnerSessionID == session.id, state == .routed else { return }
        guard !pcmStarted else { return }
        guard let snapshot = originalSnapshot else { return }
        guard await pcmController.start(reason: "takeover") else {
            logger.log("[CALL-AUDIO] pcm start failed — emergency-restoring route session=\(session.id)")
            await rollback(to: snapshot, ownerID: session.id, stage: "pcm-start", activatedCapture: true, activatedInject: true)
            return
        }
        pcmStarted = true
        await realtimeSession.connect(reason: "takeover")
    }

    private func fail(ownerID: String, stage: String) {
        logger.log("[CALL-AUDIO] takeover failed stage=\(stage) session=\(ownerID)")
        excludedSessionIDs.insert(ownerID)
        state = .failed
    }

    /// §13 — all-or-nothing: any partial state gets driven back toward the original snapshot,
    /// never left half-applied. §9 — "rollback result=success" is now only logged if *every*
    /// required postcondition holds, including the recovery record actually being gone (verified
    /// via a fresh `load()`, not assumed from the `clear()` call alone).
    private func rollback(to snapshot: CallAudioRouteSnapshot, ownerID: String, stage: String, activatedCapture: Bool, activatedInject: Bool) async {
        logger.log("[CALL-AUDIO] takeover failed stage=\(stage) session=\(ownerID)")
        logger.log("[CALL-AUDIO] rollback started session=\(ownerID)")

        // §22: PCM (if it ever started — most rollback stages fire before it would have) must be
        // fully stopped before any route-restoring setter call below. Idempotent/no-op when PCM
        // was never running (true for every stage except "pcm-start").
        await realtimeSession.disconnect(reason: "rollback")
        await pcmController.stop(reason: "rollback")
        pcmStarted = false
        stopContinuityOutputMute()

        var success = true
        if !routeController.setDefaultOutputDevice(uid: snapshot.outputUID) { success = false }
        if !routeController.setDefaultInputDevice(uid: snapshot.inputUID) { success = false }
        if activatedInject, !deviceActivator.setInjectActive(false) { success = false }
        if activatedCapture, !deviceActivator.setCaptureActive(false) { success = false }

        let convergence = await waitForRouteConvergence(target: snapshot)
        if !convergence.converged {
            logger.log("[CALL-AUDIO] rollback route restoration timeout attempts=\(convergence.attempts) elapsedMs=\(convergence.elapsedMs) \(convergence.timeoutLogSuffix) session=\(ownerID)")
            success = false
        }

        if !clearRecoveryRecord() {
            logger.log("[CALL-AUDIO] rollback recovery-record deletion failed session=\(ownerID)")
            success = false
        }

        originalSnapshot = nil
        routeOwnerSessionID = nil
        excludedSessionIDs.insert(ownerID)
        // Rollback succeeded ⇒ back to a clean idle state, ready for the *next* call — but this
        // session is still permanently excluded above. Rollback itself failing is a genuinely
        // stuck state worth surfacing distinctly.
        state = success ? .idle : .failed
        logger.log("[CALL-AUDIO] rollback result=\(success ? "success" : "failure") session=\(ownerID)")
        onRouteMutated?("rollback")
    }

    // MARK: - Restore (§15/§17)

    /// §12 — restoration readback is subject to the exact same CoreAudio settling behavior as
    /// forward takeover, so it uses the same bounded convergence check, not an immediate readback.
    private func restore(reason: String) async {
        guard let sessionID = routeOwnerSessionID, let snapshot = originalSnapshot else { return }
        guard state == .routed || state == .preparing else { return } // idempotent (§27/§36)

        state = .restoring
        logger.log("[CALL-AUDIO] restore started reason=\(reason) session=\(sessionID)")

        // §22: PCM must be completely stopped before Default Output/Input are restored — never
        // leave an active IOProc referencing a device that's about to be handed back/deactivated.
        await realtimeSession.disconnect(reason: reason)
        await pcmController.stop(reason: reason)
        pcmStarted = false
        stopContinuityOutputMute()

        let outputOK = routeController.setDefaultOutputDevice(uid: snapshot.outputUID)
        let inputOK = routeController.setDefaultInputDevice(uid: snapshot.inputUID)
        let convergence = await waitForRouteConvergence(target: snapshot)
        let verified = outputOK && inputOK && convergence.converged
        if verified {
            logger.log("[CALL-AUDIO] restore verification pass attempts=\(convergence.attempts) elapsedMs=\(convergence.elapsedMs)")
        } else {
            logger.log("[CALL-AUDIO] restore verification failed attempts=\(convergence.attempts) elapsedMs=\(convergence.elapsedMs) \(convergence.timeoutLogSuffix) session=\(sessionID)")
        }

        deviceActivator.setInjectActive(false)
        logger.log("[CALL-AUDIO] inject inactive")
        deviceActivator.setCaptureActive(false)
        logger.log("[CALL-AUDIO] capture inactive")

        if !clearRecoveryRecord() {
            logger.log("[CALL-AUDIO] restore recovery-record deletion failed session=\(sessionID)")
        }
        originalSnapshot = nil
        routeOwnerSessionID = nil
        state = .idle
        logger.log("[CALL-AUDIO] state=idle")
        onRouteMutated?(reason)
    }

    // MARK: - Route convergence (§3-§5)

    struct RouteConvergenceResult {
        let converged: Bool
        let attempts: Int
        let elapsedMs: Int
        let inputMatch: Bool
        let outputMatch: Bool
        let systemOutputMatch: Bool
        /// §13 of the investigation: the last-observed identities, so a timeout log is
        /// self-contained evidence (expected vs. actually observed) rather than just booleans.
        let target: CallAudioRouteSnapshot
        let lastObserved: CallAudioRouteSnapshot?

        /// One `[CALL-AUDIO-ROUTE-VERIFY]` diagnostic line — used by every timeout call site so the
        /// expected/observed identity fields never drift out of sync between them.
        var timeoutLogSuffix: String {
            "expectedInputUID=\(target.inputUID) observedInputUID=\(lastObserved?.inputUID ?? "nil") "
                + "expectedOutputUID=\(target.outputUID) observedOutputUID=\(lastObserved?.outputUID ?? "nil") "
                + "expectedSystemOutputUID=\(target.systemOutputUID) observedSystemOutputUID=\(lastObserved?.systemOutputUID ?? "nil")"
        }
    }

    /// Polls `routeController.currentRouteSnapshot()` up to `convergenceMaxAttempts` times,
    /// `convergencePollNanoseconds` apart, returning the instant the target is observed rather
    /// than waiting out the full budget once converged. Bounded — a target that never converges
    /// times out deterministically rather than hanging.
    private func waitForRouteConvergence(target: CallAudioRouteSnapshot) async -> RouteConvergenceResult {
        let start = Date()
        var lastInputMatch = false
        var lastOutputMatch = false
        var lastSystemOutputMatch = false
        var lastObserved: CallAudioRouteSnapshot?

        for attempt in 1...convergenceMaxAttempts {
            if let current = routeController.currentRouteSnapshot() {
                lastObserved = current
                lastOutputMatch = current.outputUID == target.outputUID
                lastInputMatch = current.inputUID == target.inputUID
                lastSystemOutputMatch = current.systemOutputUID == target.systemOutputUID
                if lastOutputMatch && lastInputMatch && lastSystemOutputMatch {
                    return RouteConvergenceResult(
                        converged: true, attempts: attempt, elapsedMs: Int(Date().timeIntervalSince(start) * 1000),
                        inputMatch: true, outputMatch: true, systemOutputMatch: true, target: target, lastObserved: current
                    )
                }
            }
            if attempt < convergenceMaxAttempts {
                try? await Task.sleep(nanoseconds: convergencePollNanoseconds)
            }
        }

        return RouteConvergenceResult(
            converged: false, attempts: convergenceMaxAttempts, elapsedMs: Int(Date().timeIntervalSince(start) * 1000),
            inputMatch: lastInputMatch, outputMatch: lastOutputMatch, systemOutputMatch: lastSystemOutputMatch,
            target: target, lastObserved: lastObserved
        )
    }

    /// §31/§32 investigation — UID-based (never AudioObjectID-based, which is deliberately never
    /// treated as stable identity anywhere in this controller). Returns the offending snapshot
    /// (for the `[CALL-AUDIO] route-ownership-lost` diagnostic's expected-vs-observed fields)
    /// rather than a bare `Bool`, so the caller never needs a second, redundant
    /// `currentRouteSnapshot()` call just to explain why this fired.
    private func lostRouteOwnershipSnapshot() -> CallAudioRouteSnapshot? {
        guard let current = routeController.currentRouteSnapshot() else { return nil }
        let lost = current.inputUID != JarvisAudioDeviceUIDs.inject
            || current.outputUID != JarvisAudioDeviceUIDs.capture
        return lost ? current : nil
    }

    /// Real-device evidence (2026-08-19): Capture as default output is not enough — Continuity
    /// (`avconferenced`) keeps a second HAL client on the original speaker. Hogging that speaker
    /// evicts Zoom/YouTube too. A muted Core Audio process tap silences only `avconferenced`.
    /// Done only after a real call takeover. Failure does not fail takeover.
    private func startContinuityOutputMute() {
        let bundles = CallAudioProcessMutePolicy.continuityOutputBundleIDs
        let ok = processMute.startMuting(bundleIDs: bundles)
        logger.log("[CALL-AUDIO] continuity-output mute start bundles=\(bundles.joined(separator: ",")) result=\(ok ? "success" : "failure")")
    }

    private func stopContinuityOutputMute() {
        guard processMute.isMuting else { return }
        processMute.stopMuting()
        logger.log("[CALL-AUDIO] continuity-output mute stop")
    }

    /// Previous builds hogged the original speaker. Startup recovery still releases a leftover hog.
    private func releaseHogIfPresent(uid: String) {
        guard !isJarvisDeviceUID(uid), routeController.deviceExists(uid: uid) else { return }
        guard let current = routeController.hogPID(uid: uid), current != -1 else { return }
        let ok = routeController.setHogPID(uid: uid, pid: -1)
        logger.log("[CALL-AUDIO] original-output unhog uid=\(uid) previousPID=\(current) result=\(ok ? "success" : "failure") source=recovery")
    }

    private func isJarvisDeviceUID(_ uid: String) -> Bool {
        uid == JarvisAudioDeviceUIDs.capture || uid == JarvisAudioDeviceUIDs.inject || uid == JarvisAudioDeviceUIDs.tap
    }

    /// §10 — the published flag always reflects a fresh read of the store, never an assumption
    /// that `save()` succeeded.
    private func saveRecoveryRecord(_ record: CallAudioRecoveryRecord) {
        recoveryStore.save(record)
        hasPersistedRecoveryRecord = recoveryStore.load() != nil
    }

    /// §9/§10 — returns whether the record is actually gone afterward (verified via a fresh
    /// `load()`), which callers use as a required postcondition for reporting rollback/restore
    /// success — never assumed from the `clear()` call's own return value alone.
    @discardableResult
    private func clearRecoveryRecord() -> Bool {
        recoveryStore.clear()
        let stillPresent = recoveryStore.load() != nil
        hasPersistedRecoveryRecord = stillPresent
        return !stillPresent
    }
}
