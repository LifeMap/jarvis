#include "JarvisCaptureRXRing.h"

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static size_t JarvisCaptureRXRingByteCount(uint32_t channelCount, uint32_t capacityFrames) {
    return sizeof(JarvisCaptureRXSharedHeader) + (size_t)channelCount * (size_t)capacityFrames * sizeof(float);
}

static void JarvisCaptureRXRingResetHeader(JarvisCaptureRXSharedHeader *header, float *samples, uint32_t channelCount, uint32_t capacityFrames) {
    header->magic = JARVIS_CAPTURE_RX_MAGIC;
    header->version = JARVIS_CAPTURE_RX_VERSION;
    header->channelCount = channelCount;
    header->capacityFrames = capacityFrames;
    __atomic_store_n(&header->writeIndex, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&header->readIndex, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&header->underrunCount, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&header->overrunFrameCount, 0, __ATOMIC_RELAXED);
    memset(samples, 0, (size_t)channelCount * (size_t)capacityFrames * sizeof(float));
}

static bool JarvisCaptureRXRingBind(JarvisCaptureRXRing *ring, JarvisCaptureRXSharedHeader *header, size_t mappingSize, int fd, bool heapAllocated, bool owner) {
    if (header->magic != JARVIS_CAPTURE_RX_MAGIC || header->version != JARVIS_CAPTURE_RX_VERSION) {
        return false;
    }
    if (header->channelCount == 0 || header->capacityFrames == 0) {
        return false;
    }
    ring->header = header;
    ring->samples = (float *)(header + 1);
    ring->mappingSize = mappingSize;
    ring->fd = fd;
    ring->mapped = true;
    ring->heapAllocated = heapAllocated;
    ring->owner = owner;
    return true;
}

static bool JarvisCaptureRXRingMapShared(JarvisCaptureRXRing *ring, bool create, const char *name) {
    memset(ring, 0, sizeof(*ring));
    ring->fd = -1;
    if (name == NULL || name[0] == '\0') return false;

    const uint32_t channels = JARVIS_CAPTURE_RX_CHANNEL_COUNT;
    const uint32_t capacity = JARVIS_CAPTURE_RX_CAPACITY_FRAMES;
    const size_t mappingSize = JarvisCaptureRXRingByteCount(channels, capacity);
    const int oflag = create ? (O_RDWR | O_CREAT) : O_RDWR;
    const int fd = shm_open(name, oflag, 0666);
    if (fd < 0) {
        return false;
    }
    if (create) {
        (void)fchmod(fd, 0666);
        if (ftruncate(fd, (off_t)mappingSize) != 0) {
            close(fd);
            return false;
        }
    }

    void *mapped = mmap(NULL, mappingSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapped == MAP_FAILED) {
        close(fd);
        return false;
    }

    JarvisCaptureRXSharedHeader *header = (JarvisCaptureRXSharedHeader *)mapped;
    float *samples = (float *)(header + 1);
    if (create) {
        JarvisCaptureRXRingResetHeader(header, samples, channels, capacity);
    }

    if (!JarvisCaptureRXRingBind(ring, header, mappingSize, fd, false, create)) {
        munmap(mapped, mappingSize);
        close(fd);
        memset(ring, 0, sizeof(*ring));
        ring->fd = -1;
        return false;
    }
    return true;
}

bool JarvisCaptureRXRingCreateNamed(JarvisCaptureRXRing *ring, const char *name) {
    if (ring == NULL) return false;
    return JarvisCaptureRXRingMapShared(ring, true, name);
}

bool JarvisCaptureRXRingOpenNamed(JarvisCaptureRXRing *ring, const char *name) {
    if (ring == NULL) return false;
    return JarvisCaptureRXRingMapShared(ring, false, name);
}

bool JarvisCaptureRXRingCreate(JarvisCaptureRXRing *ring) {
    return JarvisCaptureRXRingCreateNamed(ring, JARVIS_CAPTURE_RX_RING_NAME);
}

bool JarvisCaptureRXRingOpen(JarvisCaptureRXRing *ring) {
    return JarvisCaptureRXRingOpenNamed(ring, JARVIS_CAPTURE_RX_RING_NAME);
}

bool JarvisCaptureRXRingInitInMemory(JarvisCaptureRXRing *ring, uint32_t channelCount, uint32_t capacityFrames) {
    if (ring == NULL || channelCount == 0 || capacityFrames == 0) return false;
    memset(ring, 0, sizeof(*ring));
    ring->fd = -1;
    const size_t mappingSize = JarvisCaptureRXRingByteCount(channelCount, capacityFrames);
    JarvisCaptureRXSharedHeader *header = (JarvisCaptureRXSharedHeader *)calloc(1, mappingSize);
    if (header == NULL) return false;
    float *samples = (float *)(header + 1);
    JarvisCaptureRXRingResetHeader(header, samples, channelCount, capacityFrames);
    return JarvisCaptureRXRingBind(ring, header, mappingSize, -1, true, true);
}

void JarvisCaptureRXRingClose(JarvisCaptureRXRing *ring) {
    if (ring == NULL) return;
    if (ring->heapAllocated) {
        free(ring->header);
    } else if (ring->header != NULL && ring->mappingSize > 0) {
        munmap(ring->header, ring->mappingSize);
        if (ring->fd >= 0) {
            close(ring->fd);
        }
    }
    memset(ring, 0, sizeof(*ring));
    ring->fd = -1;
}

bool JarvisCaptureRXRingIsMapped(const JarvisCaptureRXRing *ring) {
    return ring != NULL && ring->mapped && ring->header != NULL && ring->samples != NULL;
}

void JarvisCaptureRXRingWrite(JarvisCaptureRXRing *ring, const float *frames, uint32_t frameCount) {
    if (!JarvisCaptureRXRingIsMapped(ring) || frames == NULL || frameCount == 0) return;

    const uint32_t channels = ring->header->channelCount;
    const uint32_t capacity = ring->header->capacityFrames;
    uint64_t writeIndex = __atomic_load_n(&ring->header->writeIndex, __ATOMIC_RELAXED);
    uint64_t readIndex = __atomic_load_n(&ring->header->readIndex, __ATOMIC_RELAXED);

    for (uint32_t frame = 0; frame < frameCount; frame++) {
        uint64_t slot = (writeIndex + frame) % capacity;
        memcpy(&ring->samples[slot * channels], &frames[(size_t)frame * channels], channels * sizeof(float));
    }

    uint64_t newWriteIndex = writeIndex + frameCount;
    uint64_t bufferedFrames = newWriteIndex - readIndex;
    if (bufferedFrames > capacity) {
        uint64_t dropped = bufferedFrames - capacity;
        __atomic_fetch_add(&ring->header->overrunFrameCount, dropped, __ATOMIC_RELAXED);
        __atomic_store_n(&ring->header->readIndex, newWriteIndex - capacity, __ATOMIC_RELAXED);
    }
    __atomic_store_n(&ring->header->writeIndex, newWriteIndex, __ATOMIC_RELEASE);
}

void JarvisCaptureRXRingTapLatest(JarvisCaptureRXRing *ring, float *outFrames, uint32_t frameCount) {
    if (outFrames == NULL || frameCount == 0) return;
    if (!JarvisCaptureRXRingIsMapped(ring)) {
        memset(outFrames, 0, (size_t)frameCount * JARVIS_CAPTURE_RX_CHANNEL_COUNT * sizeof(float));
        return;
    }

    const uint32_t channels = ring->header->channelCount;
    const uint32_t capacity = ring->header->capacityFrames;
    uint64_t writeIndex = __atomic_load_n(&ring->header->writeIndex, __ATOMIC_ACQUIRE);
    uint64_t available = writeIndex < (uint64_t)capacity ? writeIndex : (uint64_t)capacity;
    uint32_t toCopy = available < (uint64_t)frameCount ? (uint32_t)available : frameCount;
    uint64_t start = writeIndex - toCopy;

    for (uint32_t frame = 0; frame < toCopy; frame++) {
        uint64_t slot = (start + frame) % capacity;
        memcpy(&outFrames[(size_t)frame * channels], &ring->samples[slot * channels], channels * sizeof(float));
    }
    if (toCopy < frameCount) {
        memset(&outFrames[(size_t)toCopy * channels], 0, (size_t)(frameCount - toCopy) * channels * sizeof(float));
        __atomic_fetch_add(&ring->header->underrunCount, 1, __ATOMIC_RELAXED);
    }
}
