#ifndef JARVIS_CAPTURE_RX_RING_H
#define JARVIS_CAPTURE_RX_RING_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

/*
 * CHECKPOINT 2 RX transport. Phone.app's caller PCM is only visible in the driver's Capture
 * WriteMix; HAL never calls plugin ReadInput for Bridge's extra input client. This ring is the
 * process-shared copy of that WriteMix so Bridge can tap it without a second HAL input client.
 *
 * POSIX shm name is fixed. The driver Create()s (and resets) it; Bridge Open()s it. If the
 * helper UID/sandbox cannot publish 0666 shm, Create/Open fail and the driver still publishes
 * the last-N-frame custom property fallback (`Rrxc`).
 *
 * Write/TapLatest are lock-free and never allocate — WriteMix-safe.
 */

#define JARVIS_CAPTURE_RX_RING_NAME "/jarvis-callbridge-capture-rx"
#define JARVIS_SPEAKER_TX_RING_NAME "/jarvis-callbridge-speaker-tx"
#define JARVIS_CAPTURE_RX_MAGIC 0x4A525852u /* 'JRXR' */
#define JARVIS_CAPTURE_RX_VERSION 1u
#define JARVIS_CAPTURE_RX_CHANNEL_COUNT 2u
#define JARVIS_CAPTURE_RX_CAPACITY_FRAMES 48000u

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t channelCount;
    uint32_t capacityFrames;
    uint64_t writeIndex;
    uint64_t readIndex;
    uint64_t underrunCount;
    uint64_t overrunFrameCount;
} JarvisCaptureRXSharedHeader;

typedef struct {
    JarvisCaptureRXSharedHeader *header;
    float *samples;
    size_t mappingSize;
    int fd;
    bool mapped;
    bool heapAllocated;
    bool owner;
} JarvisCaptureRXRing;

/* Driver Initialize — creates or resets the named shm. Returns false if shm is unavailable. */
bool JarvisCaptureRXRingCreate(JarvisCaptureRXRing *ring);
bool JarvisCaptureRXRingCreateNamed(JarvisCaptureRXRing *ring, const char *name);

/* Bridge PCM start — maps an existing shm. Returns false if missing or magic/version mismatch. */
bool JarvisCaptureRXRingOpen(JarvisCaptureRXRing *ring);
bool JarvisCaptureRXRingOpenNamed(JarvisCaptureRXRing *ring, const char *name);

/* Heap-backed ring for unit tests (no shm). */
bool JarvisCaptureRXRingInitInMemory(JarvisCaptureRXRing *ring, uint32_t channelCount, uint32_t capacityFrames);

void JarvisCaptureRXRingClose(JarvisCaptureRXRing *ring);

bool JarvisCaptureRXRingIsMapped(const JarvisCaptureRXRing *ring);

/* Producer — Capture WriteMix. No-op if the ring is not mapped. */
void JarvisCaptureRXRingWrite(JarvisCaptureRXRing *ring, const float *frames, uint32_t frameCount);

/* Non-destructive monitor of the newest `frameCount` frames. Silence-pads a short ring. */
void JarvisCaptureRXRingTapLatest(JarvisCaptureRXRing *ring, float *outFrames, uint32_t frameCount);

#endif /* JARVIS_CAPTURE_RX_RING_H */
