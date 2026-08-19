#include "JarvisLoopbackBuffer.h"

#include <stdlib.h>
#include <string.h>

bool JarvisLoopbackBufferInit(JarvisLoopbackBuffer *buffer, uint32_t channelCount, uint32_t capacityFrames) {
    if (buffer == NULL || channelCount == 0 || capacityFrames == 0) {
        return false;
    }
    size_t sampleCount = (size_t)channelCount * (size_t)capacityFrames;
    float *samples = (float *)calloc(sampleCount, sizeof(float));
    if (samples == NULL) {
        return false;
    }

    buffer->channelCount = channelCount;
    buffer->capacityFrames = capacityFrames;
    buffer->writeIndex = 0;
    buffer->readIndex = 0;
    buffer->underrunCount = 0;
    buffer->overrunFrameCount = 0;
    buffer->samples = samples;
    return true;
}

void JarvisLoopbackBufferDestroy(JarvisLoopbackBuffer *buffer) {
    if (buffer == NULL) return;
    free(buffer->samples);
    buffer->samples = NULL;
    buffer->channelCount = 0;
    buffer->capacityFrames = 0;
}

void JarvisLoopbackBufferReset(JarvisLoopbackBuffer *buffer) {
    if (buffer == NULL || buffer->samples == NULL) return;
    memset(buffer->samples, 0, (size_t)buffer->channelCount * (size_t)buffer->capacityFrames * sizeof(float));
    __atomic_store_n(&buffer->writeIndex, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&buffer->readIndex, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&buffer->underrunCount, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&buffer->overrunFrameCount, 0, __ATOMIC_RELAXED);
}

void JarvisLoopbackBufferWrite(JarvisLoopbackBuffer *buffer, const float *frames, uint32_t frameCount) {
    if (buffer == NULL || buffer->samples == NULL || frames == NULL || frameCount == 0) return;

    const uint32_t channels = buffer->channelCount;
    const uint32_t capacity = buffer->capacityFrames;
    uint64_t writeIndex = __atomic_load_n(&buffer->writeIndex, __ATOMIC_RELAXED);
    uint64_t readIndex = __atomic_load_n(&buffer->readIndex, __ATOMIC_RELAXED);

    for (uint32_t frame = 0; frame < frameCount; frame++) {
        uint64_t slot = (writeIndex + frame) % capacity;
        memcpy(&buffer->samples[slot * channels], &frames[(size_t)frame * channels], channels * sizeof(float));
    }

    uint64_t newWriteIndex = writeIndex + frameCount;

    /* Overrun: the writer has produced more than a full buffer ahead of the reader. Drop the
       oldest unread frames by advancing readIndex so the reader resyncs to the newest data. */
    uint64_t bufferedFrames = newWriteIndex - readIndex;
    if (bufferedFrames > capacity) {
        uint64_t dropped = bufferedFrames - capacity;
        __atomic_fetch_add(&buffer->overrunFrameCount, dropped, __ATOMIC_RELAXED);
        __atomic_store_n(&buffer->readIndex, newWriteIndex - capacity, __ATOMIC_RELAXED);
    }

    __atomic_store_n(&buffer->writeIndex, newWriteIndex, __ATOMIC_RELEASE);
}

void JarvisLoopbackBufferRead(JarvisLoopbackBuffer *buffer, float *outFrames, uint32_t frameCount) {
    if (buffer == NULL || outFrames == NULL || frameCount == 0) return;
    if (buffer->samples == NULL) {
        memset(outFrames, 0, (size_t)frameCount * buffer->channelCount * sizeof(float));
        return;
    }

    const uint32_t channels = buffer->channelCount;
    const uint32_t capacity = buffer->capacityFrames;
    uint64_t writeIndex = __atomic_load_n(&buffer->writeIndex, __ATOMIC_ACQUIRE);
    uint64_t readIndex = __atomic_load_n(&buffer->readIndex, __ATOMIC_RELAXED);

    uint64_t available = writeIndex >= readIndex ? writeIndex - readIndex : 0;
    if (available > capacity) {
        readIndex = writeIndex - capacity;
        available = capacity;
    }

    uint32_t framesToCopy = (uint32_t)(available < frameCount ? available : frameCount);
    for (uint32_t frame = 0; frame < framesToCopy; frame++) {
        uint64_t slot = (readIndex + frame) % capacity;
        memcpy(&outFrames[(size_t)frame * channels], &buffer->samples[slot * channels], channels * sizeof(float));
    }
    if (framesToCopy < frameCount) {
        size_t silenceOffset = (size_t)framesToCopy * channels;
        size_t silenceCount = (size_t)(frameCount - framesToCopy) * channels;
        memset(&outFrames[silenceOffset], 0, silenceCount * sizeof(float));
        __atomic_fetch_add(&buffer->underrunCount, 1, __ATOMIC_RELAXED);
    }

    __atomic_store_n(&buffer->readIndex, readIndex + framesToCopy, __ATOMIC_RELAXED);
}

void JarvisLoopbackBufferTapLatest(JarvisLoopbackBuffer *buffer, float *outFrames, uint32_t frameCount) {
    if (buffer == NULL || outFrames == NULL || frameCount == 0) return;
    const uint32_t channels = buffer->channelCount;
    if (buffer->samples == NULL) {
        memset(outFrames, 0, (size_t)frameCount * channels * sizeof(float));
        return;
    }

    const uint32_t capacity = buffer->capacityFrames;
    uint64_t writeIndex = __atomic_load_n(&buffer->writeIndex, __ATOMIC_ACQUIRE);
    uint64_t available = writeIndex < (uint64_t)capacity ? writeIndex : (uint64_t)capacity;
    uint32_t toCopy = available < (uint64_t)frameCount ? (uint32_t)available : frameCount;
    uint64_t start = writeIndex - toCopy;

    for (uint32_t frame = 0; frame < toCopy; frame++) {
        uint64_t slot = (start + frame) % capacity;
        memcpy(&outFrames[(size_t)frame * channels], &buffer->samples[slot * channels], channels * sizeof(float));
    }
    if (toCopy < frameCount) {
        memset(&outFrames[(size_t)toCopy * channels], 0, (size_t)(frameCount - toCopy) * channels * sizeof(float));
        __atomic_fetch_add(&buffer->underrunCount, 1, __ATOMIC_RELAXED);
    }
}

void JarvisLoopbackBufferGetCounters(const JarvisLoopbackBuffer *buffer, uint64_t *outWriteFrames, uint64_t *outReadFrames, uint64_t *outUnderrunCount, uint64_t *outOverrunFrameCount) {
    if (buffer == NULL) return;
    if (outWriteFrames) *outWriteFrames = __atomic_load_n(&buffer->writeIndex, __ATOMIC_RELAXED);
    if (outReadFrames) *outReadFrames = __atomic_load_n(&buffer->readIndex, __ATOMIC_RELAXED);
    if (outUnderrunCount) *outUnderrunCount = __atomic_load_n(&buffer->underrunCount, __ATOMIC_RELAXED);
    if (outOverrunFrameCount) *outOverrunFrameCount = __atomic_load_n(&buffer->overrunFrameCount, __ATOMIC_RELAXED);
}
