#ifndef JARVIS_CALL_AUDIO_PLUGIN_TYPES_H
#define JARVIS_CALL_AUDIO_PLUGIN_TYPES_H

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>

#include "JarvisLoopbackBuffer.h"
#include "JarvisCaptureRXRing.h"

/*
 * CB v2 Phase 1 "JarvisCallAudio.driver" — two independent virtual loopback devices:
 *
 *   Jarvis Call Capture  (Phone/Continuity output -> Bridge Caller RX)
 *   Jarvis Call Inject   (Bridge AI/User TX -> Phone.app microphone input)
 *   Jarvis Speaker       (system default output stand-in; WriteMix published to speaker TX ring)
 *
 * Each device has its own Output stream and Input stream, connected internally by its own
 * JarvisLoopbackBuffer: whatever a client writes to the device's Output is what every input
 * client taps back from the device's Input (non-destructive — a default-output client's unused
 * duplex ReadInput must not starve Bridge). HAL never delivers plugin ReadInput to a second
 * input client on Capture, so Capture WriteMix also publishes to a process-shared RX ring
 * (`JarvisCaptureRXRing`) and a last-N-frame custom property (`Rrxc`) for Bridge.
 *
 * Both devices report CanBeDefaultDevice/CanBeDefaultSystemDevice = false in every scope, which
 * structurally prevents macOS from ever offering them as the system default input/output — this
 * is the primary safety mechanism behind PRD §10's "installing/activating the driver must never
 * change the default audio route" requirement, enforced by the HAL contract itself rather than by
 * driver-side promises.
 *
 * Devices start hidden (kAudioDevicePropertyIsHidden = 1) and inactive. A custom, settable
 * property (kJarvisDevicePropertyActive) toggles both isHidden and isActive together and resets
 * the device's loopback buffer, so a freshly (re)activated device never plays back stale audio
 * from a previous session (PRD §8, §11).
 */

enum {
    kJarvisCallAudio_Capture_Device       = 2,
    kJarvisCallAudio_Capture_OutputStream = 3,
    kJarvisCallAudio_Capture_InputStream  = 4,
    kJarvisCallAudio_Inject_Device        = 5,
    kJarvisCallAudio_Inject_OutputStream  = 6,
    kJarvisCallAudio_Inject_InputStream   = 7,
    /* Capture loopback monitor. Same duplex stream layout as Capture/Inject — an input-only
       Tap made coreaudiod spin at ~150% CPU after install. WriteMix on Tap must not enter
       Capture's ring; ReadInput taps Capture's ring. */
    kJarvisCallAudio_Tap_Device           = 8,
    kJarvisCallAudio_Tap_OutputStream     = 9,
    kJarvisCallAudio_Tap_InputStream      = 10,
    /* Dedicated default-output speaker. IDs stay contiguous after Tap so HAL does not
       probe a hole (object 9 did that once and hung InitializeDevices). */
    kJarvisCallAudio_Speaker_Device       = 11,
    kJarvisCallAudio_Speaker_OutputStream = 12,
    kJarvisCallAudio_Speaker_InputStream  = 13
};

#define JARVIS_CALL_AUDIO_DEVICE_COUNT 4

#define JARVIS_CALL_AUDIO_SAMPLE_RATE 48000u
#define JARVIS_CALL_AUDIO_CHANNEL_COUNT 2u
#define JARVIS_CALL_AUDIO_RING_SECONDS 1u
#define JARVIS_CALL_AUDIO_CAPACITY_FRAMES (JARVIS_CALL_AUDIO_SAMPLE_RATE * JARVIS_CALL_AUDIO_RING_SECONDS)
// Must be >= 10923 per AudioServerPlugIn.h's documented minimum for
// kAudioDevicePropertyZeroTimeStampPeriod.
#define JARVIS_CALL_AUDIO_ZERO_TIMESTAMP_PERIOD JARVIS_CALL_AUDIO_SAMPLE_RATE

/* Custom, settable device-scope properties used as the Phase 1 control plane (PRD §12).
   Selectors are mixed-case ASCII on purpose to avoid colliding with any current or future
   Apple-reserved (all-lowercase) FourCharCode. */
#define kJarvisDevicePropertyActive        'Ract'  /* UInt32 0/1, gettable+settable */
#define kJarvisDevicePropertyClearBuffers  'Rclr'  /* write-only trigger, any value resets */

/* Phase 3 CHECKPOINT 2 RX investigation (§13) — read-only PCM stage diagnostics, added to
   root-cause "RX callbacks run but signal is always exactly zero" without guessing which of the
   four pipeline stages (client->driver Output, driver->loopback write, loopback->driver Input
   read, driver->Bridge C IOProc) is where real signal is lost. One versioned snapshot struct,
   matching the project's existing "one selector per logical property" convention rather than
   many unrelated ones. Gettable only — never appears in Driver_SetPropertyData's handled cases,
   so a Set falls through to the existing kAudioHardwareUnsupportedOperationError default. */
#define kJarvisDevicePropertyPCMDiagnostics 'Rpcm'
/* Last WriteMix chunk on Capture — control-plane fallback when POSIX shm is unavailable. */
#define kJarvisDevicePropertyCaptureRXChunk 'Rrxc'
#define JARVIS_CAPTURE_RX_FALLBACK_MAX_FRAMES 1024u

typedef struct {
    uint32_t version; /* = 1 */
    uint32_t frameCount;
    uint32_t channelCount;
    uint32_t reserved;
    float samples[JARVIS_CAPTURE_RX_FALLBACK_MAX_FRAMES * JARVIS_CALL_AUDIO_CHANNEL_COUNT];
} JarvisCaptureRXFallbackChunk;

typedef struct {
    uint32_t version; /* = 1 */
    uint32_t ioClientCount; /* live AudioDeviceStart/Stop client count (existing counter, just exposed) */

    /* Stage: a client (Phone.app, or Bridge's own IOProc) writes to this device's OUTPUT stream —
       the very first place real call audio would appear if anything is rendering here at all. */
    int64_t outputOperationCount;
    int64_t outputFrames;
    int64_t outputNonZeroCallbacks;
    float outputPeakLinear; /* most recent WriteMix callback's peak, linear — not a running max */

    /* Stage: the driver's own intra-device loopback ring (existing JarvisLoopbackBuffer counters,
       reused rather than duplicated per §10). */
    uint64_t loopbackWriteFrames;
    uint64_t loopbackReadFrames;
    uint64_t loopbackUnderrunCount;
    uint64_t loopbackOverrunFrameCount;

    /* Stage: what a driver client (Bridge's JarvisPCMCaptureIOProc/JarvisPCMInjectIOProc) actually
       receives as this device's INPUT — i.e. exactly what left the loopback ring. */
    int64_t inputOperationCount;
    int64_t inputFrames;
    int64_t inputNonZeroCallbacks;
    float inputPeakLinear; /* most recent ReadInput callback's peak, linear — not a running max */
} JarvisPCMDeviceDiagnostics;

typedef struct {
    AudioObjectID deviceObjectID;
    AudioObjectID outputStreamObjectID;
    AudioObjectID inputStreamObjectID;
    CFStringRef deviceUID;   /* static string constant, not owned/released */
    CFStringRef deviceName;  /* static string constant, not owned/released */
    JarvisLoopbackBuffer loopback;
    _Atomic bool isHidden;
    _Atomic bool isActive;
    _Atomic uint32_t ioClientCount;

    /* Phase 3 CHECKPOINT 2 RX investigation telemetry (§10/§16) — callback-local aggregation,
       single atomic publish per DoIOOperation call, no per-sample atomics, never touched from
       anywhere but Driver_DoIOOperation (RT) and the reset call sites below (control plane). */
    _Atomic int64_t pcmOutputOperationCount;
    _Atomic int64_t pcmOutputFrames;
    _Atomic int64_t pcmOutputNonZeroCallbacks;
    _Atomic uint32_t pcmOutputPeakBits; /* Float32 bit pattern, linear */
    _Atomic int64_t pcmInputOperationCount;
    _Atomic int64_t pcmInputFrames;
    _Atomic int64_t pcmInputNonZeroCallbacks;
    _Atomic uint32_t pcmInputPeakBits; /* Float32 bit pattern, linear */

    float rxFallbackSamples[2][JARVIS_CAPTURE_RX_FALLBACK_MAX_FRAMES * JARVIS_CALL_AUDIO_CHANNEL_COUNT];
    uint32_t rxFallbackFrameCount[2];
    _Atomic uint32_t rxFallbackPublishedSlot;
} JarvisCallAudioDeviceState;

void *JarvisCallAudioFactory(CFAllocatorRef allocator, CFUUIDRef typeID);
AudioServerPlugInDriverRef JarvisCallAudio_GetDriverRef(void);

#endif /* JARVIS_CALL_AUDIO_PLUGIN_TYPES_H */
