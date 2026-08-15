#ifndef JARVIS_CALL_AUDIO_PLUGIN_TYPES_H
#define JARVIS_CALL_AUDIO_PLUGIN_TYPES_H

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>

#include "JarvisLoopbackBuffer.h"

/*
 * CB v2 Phase 1 "JarvisCallAudio.driver" — two independent virtual loopback devices:
 *
 *   Jarvis Call Capture  (future: Phone.app output -> Bridge Caller RX)
 *   Jarvis Call Inject   (future: Bridge AI/User TX -> Phone.app microphone input)
 *
 * Each device has its own Output stream and Input stream, connected internally by its own
 * JarvisLoopbackBuffer: whatever a client writes to the device's Output is what the same (or
 * another) client reads back from the device's Input. There is no Bridge<->Driver custom IPC —
 * clients talk to these devices exactly like any other CoreAudio device, via standard Device I/O
 * (DoIOOperation is the only place PCM ever moves).
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
    kJarvisCallAudio_Inject_InputStream   = 7
};

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
} JarvisCallAudioDeviceState;

void *JarvisCallAudioFactory(CFAllocatorRef allocator, CFUUIDRef typeID);
AudioServerPlugInDriverRef JarvisCallAudio_GetDriverRef(void);

#endif /* JARVIS_CALL_AUDIO_PLUGIN_TYPES_H */
