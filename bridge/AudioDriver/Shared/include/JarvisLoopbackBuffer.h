#ifndef JARVIS_LOOPBACK_BUFFER_H
#define JARVIS_LOOPBACK_BUFFER_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

/*
 * CB v2 Phase 1. Pure, CoreAudio-independent loopback ring buffer used INSIDE a single HAL
 * device to connect that device's own Output stream to its own Input stream — this is
 * intra-process, in-driver audio buffering, not a Bridge<->Driver IPC mechanism (PRD explicitly
 * forbids reintroducing v1's POSIX shared-memory transport; standard CoreAudio Device I/O is
 * what any client, including the future Bridge app, uses to talk to the device from outside).
 *
 * Jarvis Call Capture and Jarvis Call Inject each own a completely separate instance of this
 * buffer — never shared, never touching each other's memory — so cross-device audio
 * contamination is structurally impossible, not just policy.
 *
 * Deliberately allocates once at Init (outside any real-time callback) and never allocates again
 * — Write/Read only do pointer arithmetic, safe to call from a HAL real-time IO thread.
 *
 * Policy:
 *   - Underrun (reader wants more than is buffered): missing tail is filled with silence.
 *   - Overrun (writer produces faster than reader drains, ring wraps): oldest frames are
 *     silently dropped — the reader simply resyncs to the newest capacityFrames of audio.
 */

typedef struct {
    uint32_t channelCount;
    uint32_t capacityFrames;
    uint64_t writeIndex;   /* monotonically increasing frame count produced */
    uint64_t readIndex;    /* monotonically increasing frame count consumed */
    uint64_t underrunCount;
    uint64_t overrunFrameCount;
    float *samples;        /* capacityFrames * channelCount, interleaved */
} JarvisLoopbackBuffer;

/* Allocates `capacityFrames * channelCount` floats. Call once, outside any real-time context. */
bool JarvisLoopbackBufferInit(JarvisLoopbackBuffer *buffer, uint32_t channelCount, uint32_t capacityFrames);

/* Frees the buffer allocated by Init. Call once, outside any real-time context. */
void JarvisLoopbackBufferDestroy(JarvisLoopbackBuffer *buffer);

/* Clears all buffered audio and counters without reallocating — used when a device transitions
   from inactive/hidden back to active so a new session never plays back stale audio from a
   previous run. */
void JarvisLoopbackBufferReset(JarvisLoopbackBuffer *buffer);

/* Producer side — called from the device's Output-stream DoIOOperation (WriteMix). Never blocks,
   never allocates. On overrun, oldest unread frames are dropped and overrunFrameCount increases. */
void JarvisLoopbackBufferWrite(JarvisLoopbackBuffer *buffer, const float *frames, uint32_t frameCount);

/* Consumer side — called from the device's Input-stream DoIOOperation (ReadInput). Never blocks,
   never allocates. On underrun, the missing tail is silence and underrunCount increases. */
void JarvisLoopbackBufferRead(JarvisLoopbackBuffer *buffer, float *outFrames, uint32_t frameCount);

#endif /* JARVIS_LOOPBACK_BUFFER_H */
