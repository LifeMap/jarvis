# Jarvis Call Bridge — CB Phase 0 (Phone.app)

This is a deliberately small macOS feasibility probe for CB Phase 0's v1.1 re-verification
(`docs/Jarvis_Call_Bridge_Client_PRD.md`). It does not implement AI, recording, cloud APIs, or a
production call bridge. See `docs/Call_Bridge_Phase_0_PhoneApp_Feasibility_Report.md` for the
current findings and `docs/Call_Bridge_Phase_0_Feasibility_Report.md` for the earlier v1.0
findings (CXCallObserver unavailable, no direct Continuity TX API) that motivated this redesign.

## Layout

- `*.swift` — the feasibility probe app (SwiftPM executable, SwiftUI shell)
- `HALPlugin/` — the "Jarvis Virtual Mic" CoreAudio HAL Audio Server Plug-in (CB Phase 0-B TX
  candidate). Separate build/install trust boundary — see `HALPlugin/README.md`.
- `Resources/tx-sample.wav` — short synthesized speech sample used by the TX virtual-mic probe

## Build and run

Prerequisites: macOS 14.2+. This environment has no Xcode installed (Command Line Tools only,
`xcodebuild` unavailable) — `swift build`/`swift run` work fine for iteration, but for reliable
TCC permission prompts (Screen Recording, Accessibility), build the packaged `.app` via
`build-app.sh` and run that instead of the raw SwiftPM binary.

```sh
cd bridge
swift build
swift run JarvisCallBridgeFeasibility
```

or, for a proper `.app` bundle with a stable identity (recommended for permission prompts):

```sh
cd bridge
./build-app.sh
open ".build/Jarvis Call Bridge Feasibility.app"
```

## What the probes mean

- **RX (`RXAudioProbe.swift`)** — targets Phone.app (`com.apple.mobilephone`) as the primary CB
  Phase 0-A candidate via ScreenCaptureKit process-audio capture, falling back to FaceTime only as
  an explicitly-labeled comparison path (never the default). Computes RMS/dBFS per buffer so a
  real-device tester can confirm actual caller speech is present, not just that buffers are
  arriving. Buffer arrival alone is never treated as RX success.
- **TX local smoke test (`TXAudioProbe.swift`)** — plays a 440Hz tone on the default system
  output. This is **not** a TX candidate — it always stays labeled local-output-only and is kept
  only to distinguish "the app can make sound" from "the app can reach a real caller".
- **TX virtual mic (`VirtualMicTXProbe.swift`)** — the actual CB Phase 0-B TX candidate. Writes
  PCM into a shared-memory ring buffer that the `HALPlugin/` driver exposes system-wide as a
  selectable microphone ("Jarvis Virtual Mic"). Requires building and manually installing the
  driver first — see `HALPlugin/README.md`. Reports `driverNotInstalled` cleanly if the driver
  isn't loaded rather than silently failing.
- **Separation (`SeparationMonitor.swift`)** — CB Phase 0-C. Logs RX and TX RMS side by side while
  both run simultaneously, for a human tester to judge feedback/loopback during a real call. No
  echo cancellation is implemented — that's explicitly out of scope for Phase 0.
- **Call state (`CallStateMonitor.swift` + `PhoneAppAccessibilityProbe.swift`)** —
  `CallStateMonitor` is the authoritative, honest signal: the public macOS SDK marks CallKit's
  `CXCallObserver` unavailable, and this app never pretends process/window presence is call-state
  detection. `PhoneAppAccessibilityProbe` is a separate, clearly-labeled best-effort *guess* via
  the Accessibility API (AXUIElement/AXObserver against Phone.app), always prefixed "Guess" in the
  UI/logs. Manual Start/Stop remains the required fallback regardless of what the guess probe
  reports (PRD §10.3/§22).

Nothing in this app claims a PASS result on its own. Only a real iPhone cellular call, run through
the procedures in `docs/Call_Bridge_Phase_0_PhoneApp_Feasibility_Report.md`, can produce one.
