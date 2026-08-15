#ifndef JARVIS_VMIC_RING_H
#define JARVIS_VMIC_RING_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

/*
 * Shared-memory single-producer/single-consumer ring buffer that carries
 * mono Float32 PCM from the Jarvis Call Bridge app (producer) into the
 * "Jarvis Virtual Mic" CoreAudio HAL plug-in (consumer), which runs inside
 * coreaudiod — a different process from the app. This header is the single
 * source of truth for both sides and is compiled twice: once into the
 * SwiftPM C target imported by the app, and once directly by the driver's
 * own clang build.
 *
 * Deliberately uses plain (non C11 `_Atomic`-qualified) fields plus
 * `__atomic` compiler builtins for cross-thread/cross-process safety. A
 * `_Atomic(uint64_t)` field would make this struct fail to import cleanly
 * into Swift via the Clang importer; plain fields with builtin atomics keep
 * both the memory layout and the Swift import path simple.
 *
 * Spike-level scope: single producer, single consumer, producer never
 * blocks (overwrites on overrun), consumer never blocks (fills silence and
 * counts underruns). No semaphores/mach ports — the HAL driver's IO thread
 * only ever peeks at shared memory, never waits on anything, since
 * DoIOOperation runs on a real-time-priority thread inside coreaudiod.
 */

#define JARVIS_VMIC_SHM_NAME "/jarvis.cbridge.vmic"
#define JARVIS_VMIC_MAGIC 0x4A564D31u /* 'JVM1' */
#define JARVIS_VMIC_VERSION 1u
#define JARVIS_VMIC_SAMPLE_RATE 48000u
#define JARVIS_VMIC_CHANNEL_COUNT 1u
#define JARVIS_VMIC_RING_SECONDS 2u
#define JARVIS_VMIC_CAPACITY_FRAMES (JARVIS_VMIC_SAMPLE_RATE * JARVIS_VMIC_RING_SECONDS)

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t channelCount;
    uint32_t capacityFrames;
    uint32_t reserved;
    uint64_t writeIndex;               /* monotonically increasing frame count produced */
    uint64_t readIndex;                /* monotonically increasing frame count consumed */
    uint64_t producerHeartbeatHostTime;
    uint64_t underrunCount;
    float samples[JARVIS_VMIC_CAPACITY_FRAMES];
} JarvisVMicRing;

const char *JarvisVMicRingVersionString(void);

/* Non-variadic wrapper around shm_open(name, O_RDWR) — Swift cannot call the
   variadic libc shm_open directly, so the app-side (attach-only, never
   creates) goes through this wrapper instead. Returns a file descriptor or
   -1 with errno set, exactly like shm_open. */
int JarvisVMicRingShmOpenExisting(const char *name);

static inline size_t JarvisVMicRingByteSize(void) {
    return sizeof(JarvisVMicRing);
}

static inline void JarvisVMicRingInitHeader(JarvisVMicRing *ring) {
    ring->magic = JARVIS_VMIC_MAGIC;
    ring->version = JARVIS_VMIC_VERSION;
    ring->sampleRate = JARVIS_VMIC_SAMPLE_RATE;
    ring->channelCount = JARVIS_VMIC_CHANNEL_COUNT;
    ring->capacityFrames = JARVIS_VMIC_CAPACITY_FRAMES;
    ring->reserved = 0;
    __atomic_store_n(&ring->writeIndex, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&ring->readIndex, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&ring->producerHeartbeatHostTime, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&ring->underrunCount, 0, __ATOMIC_RELAXED);
}

static inline bool JarvisVMicRingHeaderValid(const JarvisVMicRing *ring) {
    return ring->magic == JARVIS_VMIC_MAGIC &&
           ring->version == JARVIS_VMIC_VERSION &&
           ring->capacityFrames == JARVIS_VMIC_CAPACITY_FRAMES;
}

/* Producer side (Jarvis app). Appends frameCount mono samples. If the
   consumer has fallen behind by more than the ring capacity, the oldest
   unread data is silently overwritten (spike-level behavior: producer never
   blocks and never grows unbounded). */
static inline void JarvisVMicRingWrite(JarvisVMicRing *ring, const float *samples, uint32_t frameCount) {
    uint64_t writeIndex = __atomic_load_n(&ring->writeIndex, __ATOMIC_RELAXED);
    for (uint32_t i = 0; i < frameCount; i++) {
        uint64_t slot = (writeIndex + i) % ring->capacityFrames;
        ring->samples[slot] = samples[i];
    }
    __atomic_store_n(&ring->writeIndex, writeIndex + frameCount, __ATOMIC_RELEASE);
}

static inline void JarvisVMicRingTouchHeartbeat(JarvisVMicRing *ring, uint64_t hostTime) {
    __atomic_store_n(&ring->producerHeartbeatHostTime, hostTime, __ATOMIC_RELAXED);
}

/* Consumer side (HAL driver, real-time IO thread). Fills frameCount mono
   samples; on underrun, fills silence for the missing tail and increments
   underrunCount. Never blocks, never allocates, never logs. */
static inline void JarvisVMicRingRead(JarvisVMicRing *ring, float *outSamples, uint32_t frameCount) {
    uint64_t writeIndex = __atomic_load_n(&ring->writeIndex, __ATOMIC_ACQUIRE);
    uint64_t readIndex = __atomic_load_n(&ring->readIndex, __ATOMIC_RELAXED);
    uint64_t available = writeIndex >= readIndex ? writeIndex - readIndex : 0;
    if (available > ring->capacityFrames) {
        /* consumer fell too far behind; resync to the oldest still-valid frame */
        readIndex = writeIndex - ring->capacityFrames;
        available = ring->capacityFrames;
    }
    uint32_t framesToCopy = (uint32_t)(available < frameCount ? available : frameCount);
    for (uint32_t i = 0; i < framesToCopy; i++) {
        uint64_t slot = (readIndex + i) % ring->capacityFrames;
        outSamples[i] = ring->samples[slot];
    }
    for (uint32_t i = framesToCopy; i < frameCount; i++) {
        outSamples[i] = 0.0f;
    }
    if (framesToCopy < frameCount) {
        __atomic_fetch_add(&ring->underrunCount, 1, __ATOMIC_RELAXED);
    }
    __atomic_store_n(&ring->readIndex, readIndex + framesToCopy, __ATOMIC_RELAXED);
}

static inline uint64_t JarvisVMicRingGetUnderrunCount(const JarvisVMicRing *ring) {
    return __atomic_load_n((uint64_t *)&ring->underrunCount, __ATOMIC_RELAXED);
}

static inline uint64_t JarvisVMicRingGetProducerHeartbeat(const JarvisVMicRing *ring) {
    return __atomic_load_n((uint64_t *)&ring->producerHeartbeatHostTime, __ATOMIC_RELAXED);
}

static inline uint64_t JarvisVMicRingGetWriteIndex(const JarvisVMicRing *ring) {
    return __atomic_load_n((uint64_t *)&ring->writeIndex, __ATOMIC_RELAXED);
}

static inline uint64_t JarvisVMicRingGetReadIndex(const JarvisVMicRing *ring) {
    return __atomic_load_n((uint64_t *)&ring->readIndex, __ATOMIC_RELAXED);
}

#endif /* JARVIS_VMIC_RING_H */
