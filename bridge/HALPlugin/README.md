# Jarvis Virtual Mic — CB Phase 0-B HAL Audio Server Plug-in

This is a minimal CoreAudio HAL Audio Server Plug-in ("Jarvis Virtual Mic"): a single static,
input-only virtual microphone device, built directly with `clang` against the public
`AudioServerPlugIn.h` API — no Xcode project, no DriverKit system extension, no private/undocumented
API. It exists so Phone.app can be pointed at a microphone whose audio the Jarvis Call Bridge app
controls, as the CB Phase 0-B TX candidate described in `docs/Jarvis_Call_Bridge_Client_PRD.md`.

This has a **different trust boundary** than the rest of `bridge/`: building it is safe and
side-effect-free, but *installing* it requires `sudo` and restarts `coreaudiod` (interrupting all
system audio, including any active call). That is why install/uninstall are separate, explicitly
human-run scripts, never invoked automatically by anything else in this repository.

## Object model

- 1 PlugIn object (mandatory `kAudioObjectPlugInObject`)
- 1 Device object: `"Jarvis Virtual Mic"`, UID `com.jarvis.callbridge.virtualmic`, transport type
  `Virtual`, fixed nominal sample rate 48kHz, input-only (no output streams, no aggregate-device
  support)
- 1 Stream object: mono, Float32, 48kHz, terminal type Microphone
- 0 Control objects (no volume/mute — out of scope for a Phase 0 spike)

## Cross-process design

The driver runs *inside coreaudiod*, a different process from the Jarvis Call Bridge app. Audio
crosses that process boundary through a lock-free single-producer/single-consumer ring buffer in
POSIX shared memory, defined once in `../HALPlugin/Shared/include/JarvisVMicRing.h` and shared by
both this driver's build and the app's SwiftPM C target:

- The **driver** (`Driver_Initialize` in `PlugInInterface.c`) creates the shared memory segment
  (`shm_open(..., O_CREAT)`) and owns its lifetime.
- The **app** (`VirtualMicTXProbe.swift`) only ever attaches to an already-existing segment
  (`shm_open` without `O_CREAT`) and reports `driverNotInstalled` if it isn't there yet.
- `DoIOOperation`'s `kAudioServerPlugInIOOperationReadInput` handler runs on a real-time-priority
  thread inside coreaudiod. It never blocks, allocates, or logs — it just reads whatever is
  currently buffered (silence-filling and counting underruns if the app hasn't written enough).

The shared memory segment is created world-readable/writable (`0666`) because coreaudiod's daemon
user and the logged-in user's app process run as different UIDs. That is an accepted shortcut for
this single-user local PoC (see PRD §7.2, "1 User = 1 Mac = 1 Bridge") — flagged here as a
hardening item for any future multi-user iteration, not swept under the rug.

## Build

```sh
cd bridge/HALPlugin
./build-driver.sh
```

This compiles the three `.c` files with plain `clang` (`-std=c11`, no Xcode project needed),
links a `.driver` bundle, ad-hoc code-signs it, and then builds and runs `selftest` — a small
standalone tool that `dlopen()`s the built bundle directly and exercises the factory function,
`QueryInterface`, and a few `GetPropertyData` calls **in-process, without coreaudiod, without
sudo, without installing anything**. A selftest PASS proves the vtable links and answers
property queries correctly. It does **not** prove coreaudiod will actually load the driver, and
it does **not** prove a real caller will hear anything — those require the install + real-device
test steps below.

## Install (you run this, not an agent)

```sh
cd bridge/HALPlugin
./install.sh
```

Copies `build/JarvisVirtualMic.driver` into `/Library/Audio/Plug-Ins/HAL` (`sudo cp`, `sudo
chown`) and restarts `coreaudiod` (`sudo killall coreaudiod`) so it picks up the new plug-in. This
interrupts all system audio, including any active call — do not run it mid-call. After running,
check System Settings → Sound → Input, or Audio MIDI Setup.app, for a device named "Jarvis Virtual
Mic". If it doesn't appear, check Console.app for `coreaudiod` errors mentioning
`JarvisVirtualMic` and record them for the Phase 0 report.

## Uninstall

```sh
cd bridge/HALPlugin
./uninstall.sh
```

Removes the installed bundle and restarts `coreaudiod` again.

## Known limitations (Phase 0 scope)

- No Controls (no volume/mute) — the device is fixed at whatever level the app writes.
- No dynamic device creation (`CreateDevice`/`DestroyDevice` return
  `kAudioHardwareUnsupportedOperationError`) — one static device, always present once loaded.
- Ring buffer atomicity uses plain aligned loads/stores + compiler `__atomic` builtins rather than
  C11 `_Atomic`-qualified fields, deliberately, so the shared header stays importable into Swift
  without the Clang importer choking on `_Atomic(T)`. This is fine for a single producer/single
  consumer but is a spike-level simplification worth revisiting if this becomes a real driver
  responsible for more than a single writer.
- `GetZeroTimeStamp`'s clock model (anchor host time + `mach_timebase_info`-derived host-ticks-
  per-frame) is a standard, reasonable implementation, but has never been exercised against a real
  coreaudiod IO cycle in this environment — treat it as `IMPLEMENTED / NOT VERIFIED` until a real
  install + real audio round-trip confirms it.
