#include "include/JarvisPCMRealtime.h"

#include <JarvisCaptureRXRing.h>
#include <JarvisLoopbackBuffer.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* §14 - compile-time lock-free guarantees where the standard defines an unambiguous macro for
   the underlying type. int64_t is `long` on LP64 Darwin (both arm64 and x86_64), so
   ATOMIC_LONG_LOCK_FREE is the applicable one; ATOMIC_LLONG_LOCK_FREE is also checked so this
   still holds if int64_t were ever `long long` on some future target. The 32-bit fields use the
   plain `int`/`unsigned int`-backed macros. A value of 2 means "always lock-free" per the C11
   standard; JarvisPCMRuntimeAtomicsAreLockFree() below is the runtime fallback for anything not
   provable at compile time (§14's explicit fallback allowance).
*/
_Static_assert(ATOMIC_LONG_LOCK_FREE == 2 || ATOMIC_LLONG_LOCK_FREE == 2, "64-bit atomics must be always-lock-free on this target");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "32-bit atomics must be always-lock-free on this target");

struct JarvisPCMRuntimeContext {
    _Atomic int64_t rxFrames;
    _Atomic int64_t rxCallbacks;
    _Atomic uint32_t rxMeanSquareBits; /* Float32 bit pattern, linear (not dBFS) */
    _Atomic uint32_t rxPeakBits;       /* Float32 bit pattern, linear (not dBFS) */

    /* RX IOProc stream usage / input buffer delivery investigation - see the doc comment on
       JarvisPCMMetricsSnapshot in the header for what each field distinguishes. */
    _Atomic int64_t rxIOProcInvocations;
    _Atomic int64_t rxNullInputListCallbacks;
    _Atomic int64_t rxZeroBufferCountCallbacks;
    _Atomic uint32_t rxInputBufferCountLast;
    _Atomic int64_t rxNullDataBufferCount;
    _Atomic int64_t rxReadableDataBufferCount;
    _Atomic int64_t rxReadableNonZeroBufferCount;

    _Atomic int64_t txFrames;
    _Atomic int64_t txCallbacks;
    _Atomic int64_t txUnderrunCount;

    _Atomic int32_t toneState;         /* 0 = idle, 1 = queued, 2 = playing */
    _Atomic int32_t toneRequestFrames;

    /* Callback-owned consume countdown (Inject IOProc only). Sine/phase live on the
       WriteTXFrames producer, not here. */
    int64_t toneFramesRemaining;
    double tonePhase;

    float txRing[JARVIS_PCM_TX_RING_FRAMES * JARVIS_PCM_CHANNEL_COUNT];
    uint32_t txRingWritePos;
    uint32_t txRingReadPos;
    _Atomic uint32_t txRingCount;

    /* App consume ring — sequential RX for Realtime. Distinct from capture shm `rxRing`. */
    float rxConsume[JARVIS_PCM_TX_RING_FRAMES * JARVIS_PCM_CHANNEL_COUNT];
    uint32_t rxConsumeWritePos;
    uint32_t rxConsumeReadPos;
    _Atomic uint32_t rxConsumeCount;
    _Atomic int64_t rxOverflowCount;

    /* Capture AUHAL - set from the control plane before AudioOutputUnitStart. The render
       scratch is allocated once in Attach and freed in Destroy; the callback never allocates. */
    AudioUnit captureAudioUnit;
    float *captureRenderFrames;

    JarvisCaptureRXRing *rxRing;
    bool rxRingOwned;
    bool rxRingRequireWriteAdvance;
    uint64_t rxRingWriteIndexAtArm;
};

void JarvisPCMRuntimeClearRX(JarvisPCMRuntimeContext *context);
void JarvisPCMRuntimeClearTX(JarvisPCMRuntimeContext *context);

/* MARK: - Internal atomic helpers (file-local; never exposed to Swift - §10) */

static uint32_t EnqueueRXConsume(JarvisPCMRuntimeContext *ctx, const float *interleaved, uint32_t frameCount) {
    if (ctx == NULL || interleaved == NULL || frameCount == 0) return 0;
    uint32_t used = atomic_load_explicit(&ctx->rxConsumeCount, memory_order_acquire);
    uint32_t space = JARVIS_PCM_TX_RING_FRAMES - used;
    uint32_t take = frameCount < space ? frameCount : space;
    uint32_t pos = ctx->rxConsumeWritePos;
    for (uint32_t f = 0; f < take; f++) {
        uint32_t idx = ((pos + f) % JARVIS_PCM_TX_RING_FRAMES) * JARVIS_PCM_CHANNEL_COUNT;
        ctx->rxConsume[idx] = interleaved[f * JARVIS_PCM_CHANNEL_COUNT];
        ctx->rxConsume[idx + 1] = interleaved[f * JARVIS_PCM_CHANNEL_COUNT + 1];
    }
    ctx->rxConsumeWritePos = (pos + take) % JARVIS_PCM_TX_RING_FRAMES;
    if (take > 0) {
        atomic_fetch_add_explicit(&ctx->rxConsumeCount, take, memory_order_release);
    }
    if (take < frameCount) {
        atomic_fetch_add_explicit(&ctx->rxOverflowCount, (int64_t)(frameCount - take), memory_order_relaxed);
    }
    return take;
}

static void RecordRX(JarvisPCMRuntimeContext *ctx, int64_t frameCount, float meanSquare, float peak) {
    atomic_fetch_add_explicit(&ctx->rxFrames, frameCount, memory_order_relaxed);
    atomic_fetch_add_explicit(&ctx->rxCallbacks, 1, memory_order_relaxed);
    uint32_t meanSquareBits;
    memcpy(&meanSquareBits, &meanSquare, sizeof(meanSquareBits));
    uint32_t peakBits;
    memcpy(&peakBits, &peak, sizeof(peakBits));
    atomic_store_explicit(&ctx->rxMeanSquareBits, meanSquareBits, memory_order_relaxed);
    atomic_store_explicit(&ctx->rxPeakBits, peakBits, memory_order_relaxed);
}

static void PublishRXInterleaved(JarvisPCMRuntimeContext *ctx, const float *samples, UInt32 floatCount) {
    if (ctx == NULL || samples == NULL || floatCount == 0) return;
    double sumSquares = 0.0;
    float peak = 0.0f;
    for (UInt32 s = 0; s < floatCount; s++) {
        float sample = samples[s];
        sumSquares += (double)(sample * sample);
        float magnitude = fabsf(sample);
        if (magnitude > peak) peak = magnitude;
    }
    float meanSquare = (float)(sumSquares / (double)floatCount);
    int64_t frameCount = (int64_t)(floatCount / JARVIS_PCM_CHANNEL_COUNT);
    atomic_fetch_add_explicit(&ctx->rxReadableDataBufferCount, 1, memory_order_relaxed);
    if (peak > 0.0f) {
        atomic_fetch_add_explicit(&ctx->rxReadableNonZeroBufferCount, 1, memory_order_relaxed);
    }
    RecordRX(ctx, frameCount, meanSquare, peak);
    if (frameCount > 0) {
        (void)EnqueueRXConsume(ctx, samples, (uint32_t)frameCount);
    }
}

static void RecordTX(JarvisPCMRuntimeContext *ctx, int64_t frameCount) {
    atomic_fetch_add_explicit(&ctx->txFrames, frameCount, memory_order_relaxed);
    atomic_fetch_add_explicit(&ctx->txCallbacks, 1, memory_order_relaxed);
}

static void RecordTXUnderrun(JarvisPCMRuntimeContext *ctx) {
    atomic_fetch_add_explicit(&ctx->txUnderrunCount, 1, memory_order_relaxed);
}

/* Real-time (Inject callback) side only - claims a queued request (queued -> playing) if one
   exists and the callback isn't already mid-tone. Never blocks, never spins. */
static bool PollQueuedToneRequest(JarvisPCMRuntimeContext *ctx, int32_t *outFrames) {
    int32_t state = atomic_load_explicit(&ctx->toneState, memory_order_acquire);
    if (state != 1) return false;
    *outFrames = atomic_load_explicit(&ctx->toneRequestFrames, memory_order_acquire);
    atomic_store_explicit(&ctx->toneState, 2, memory_order_release);
    return true;
}

/* Real-time (Inject callback) side only - called exactly once, the instant the callback's own
   local frame countdown reaches zero. A plain store (not compare-exchange) is correct: the
   Inject callback is the sole writer of this transition. */
static void MarkToneComplete(JarvisPCMRuntimeContext *ctx) {
    atomic_store_explicit(&ctx->toneState, 0, memory_order_release);
}

/* MARK: - Control plane */

JarvisPCMRuntimeContext *JarvisPCMRuntimeCreate(void) {
    JarvisPCMRuntimeContext *ctx = (JarvisPCMRuntimeContext *)calloc(1, sizeof(JarvisPCMRuntimeContext));
    if (ctx == NULL) return NULL;
    JarvisPCMRuntimeReset(ctx);
    return ctx;
}

void JarvisPCMRuntimeReset(JarvisPCMRuntimeContext *context) {
    if (context == NULL) return;
    /* A zero bit pattern for rxMeanSquareBits/rxPeakBits decodes as the Float32 value 0.0, which
       is exactly the correct "nothing observed yet" linear value (Swift's dBFS floor-clamping
       conversion on the read side turns 0.0 linear into the display floor) - unlike a design
       that stored dBFS directly, no special-cased reset value is needed here. */
    atomic_init(&context->rxFrames, (int64_t)0);
    atomic_init(&context->rxCallbacks, (int64_t)0);
    atomic_init(&context->rxMeanSquareBits, (uint32_t)0);
    atomic_init(&context->rxPeakBits, (uint32_t)0);
    atomic_init(&context->rxIOProcInvocations, (int64_t)0);
    atomic_init(&context->rxNullInputListCallbacks, (int64_t)0);
    atomic_init(&context->rxZeroBufferCountCallbacks, (int64_t)0);
    atomic_init(&context->rxInputBufferCountLast, (uint32_t)0);
    atomic_init(&context->rxNullDataBufferCount, (int64_t)0);
    atomic_init(&context->rxReadableDataBufferCount, (int64_t)0);
    atomic_init(&context->rxReadableNonZeroBufferCount, (int64_t)0);
    atomic_init(&context->txFrames, (int64_t)0);
    atomic_init(&context->txCallbacks, (int64_t)0);
    atomic_init(&context->txUnderrunCount, (int64_t)0);
    atomic_init(&context->rxOverflowCount, (int64_t)0);
    atomic_init(&context->toneState, (int32_t)0);
    atomic_init(&context->toneRequestFrames, (int32_t)0);
    context->toneFramesRemaining = 0;
    context->tonePhase = 0.0;
    JarvisPCMRuntimeClearTX(context);
    JarvisPCMRuntimeClearRX(context);
    /* captureAudioUnit / captureRenderFrames are owned across reset (attach → destroy). */
}

void JarvisPCMRuntimeDestroy(JarvisPCMRuntimeContext *context) {
    if (context == NULL) return;
    if (context->rxRingOwned && context->rxRing != NULL) {
        JarvisCaptureRXRingClose(context->rxRing);
        free(context->rxRing);
    }
    context->rxRing = NULL;
    context->rxRingOwned = false;
    context->rxRingRequireWriteAdvance = false;
    context->rxRingWriteIndexAtArm = 0;
    free(context->captureRenderFrames);
    context->captureRenderFrames = NULL;
    context->captureAudioUnit = NULL;
    free(context);
}

static bool JarvisPCMRuntimeEnsureCaptureScratch(JarvisPCMRuntimeContext *context) {
    if (context == NULL) return false;
    if (context->captureRenderFrames != NULL) return true;
    context->captureRenderFrames = (float *)calloc(
        (size_t)JARVIS_PCM_CAPTURE_RENDER_MAX_FRAMES * JARVIS_PCM_CHANNEL_COUNT,
        sizeof(float)
    );
    return context->captureRenderFrames != NULL;
}

bool JarvisPCMRuntimeAttachCaptureAudioUnit(JarvisPCMRuntimeContext *context, AudioUnit audioUnit) {
    if (context == NULL || audioUnit == NULL) return false;
    if (!JarvisPCMRuntimeEnsureCaptureScratch(context)) return false;
    context->captureAudioUnit = audioUnit;
    return true;
}

bool JarvisPCMRuntimeOpenCaptureRXRing(JarvisPCMRuntimeContext *context) {
    if (context == NULL) return false;
    if (context->rxRing != NULL && JarvisCaptureRXRingIsMapped(context->rxRing)) {
        return JarvisPCMRuntimeEnsureCaptureScratch(context);
    }
    JarvisCaptureRXRing *ring = (JarvisCaptureRXRing *)calloc(1, sizeof(JarvisCaptureRXRing));
    if (ring == NULL) return false;
    if (!JarvisCaptureRXRingOpen(ring)) {
        free(ring);
        return false;
    }
    if (!JarvisPCMRuntimeEnsureCaptureScratch(context)) {
        JarvisCaptureRXRingClose(ring);
        free(ring);
        return false;
    }
    context->rxRing = ring;
    context->rxRingOwned = true;
    JarvisPCMRuntimeArmCaptureRXRingProducerCheck(context);
    return true;
}

bool JarvisPCMRuntimeAdoptCaptureRXRing(JarvisPCMRuntimeContext *context, void *ring) {
    if (context == NULL || ring == NULL) return false;
    if (!JarvisCaptureRXRingIsMapped((JarvisCaptureRXRing *)ring)) return false;
    if (!JarvisPCMRuntimeEnsureCaptureScratch(context)) return false;
    context->rxRing = (JarvisCaptureRXRing *)ring;
    context->rxRingOwned = false;
    return true;
}

bool JarvisPCMRuntimeCaptureRXRingIsMapped(const JarvisPCMRuntimeContext *context) {
    return context != NULL && JarvisCaptureRXRingIsMapped(context->rxRing);
}

void JarvisPCMRuntimeArmCaptureRXRingProducerCheck(JarvisPCMRuntimeContext *context) {
    if (!JarvisPCMRuntimeCaptureRXRingIsMapped(context)) return;
    context->rxRingWriteIndexAtArm = JarvisCaptureRXRingWriteIndex(context->rxRing);
    context->rxRingRequireWriteAdvance = true;
}

uint64_t JarvisPCMRuntimeCaptureRXRingWriteIndex(const JarvisPCMRuntimeContext *context) {
    if (!JarvisPCMRuntimeCaptureRXRingIsMapped(context)) return 0;
    return JarvisCaptureRXRingWriteIndex(context->rxRing);
}

bool JarvisPCMRuntimeCaptureRXRingProducerHasAdvanced(const JarvisPCMRuntimeContext *context) {
    if (context == NULL || !context->rxRingRequireWriteAdvance) return true;
    if (!JarvisPCMRuntimeCaptureRXRingIsMapped(context)) return true;
    return JarvisCaptureRXRingWriteIndex(context->rxRing) > context->rxRingWriteIndexAtArm;
}

void JarvisPCMRuntimeCloseCaptureRXRing(JarvisPCMRuntimeContext *context) {
    if (context == NULL) return;
    if (context->rxRingOwned && context->rxRing != NULL) {
        JarvisCaptureRXRingClose(context->rxRing);
        free(context->rxRing);
    }
    context->rxRing = NULL;
    context->rxRingOwned = false;
    context->rxRingRequireWriteAdvance = false;
    context->rxRingWriteIndexAtArm = 0;
}

uint32_t JarvisPCMRuntimePublishRXFrames(JarvisPCMRuntimeContext *context, const float *samples, uint32_t frameCount) {
    if (context == NULL || samples == NULL || frameCount == 0) return 0;
    uint32_t before = atomic_load_explicit(&context->rxConsumeCount, memory_order_acquire);
    PublishRXInterleaved(context, samples, frameCount * (UInt32)JARVIS_PCM_CHANNEL_COUNT);
    uint32_t after = atomic_load_explicit(&context->rxConsumeCount, memory_order_acquire);
    return after - before;
}

void JarvisPCMRuntimeClearRX(JarvisPCMRuntimeContext *context) {
    if (context == NULL) return;
    atomic_store_explicit(&context->rxConsumeCount, 0, memory_order_relaxed);
    context->rxConsumeWritePos = 0;
    context->rxConsumeReadPos = 0;
}

uint32_t JarvisPCMRuntimeReadRXFrames(
    JarvisPCMRuntimeContext *context,
    float *interleaved,
    uint32_t frameCount
) {
    if (context == NULL || interleaved == NULL || frameCount == 0) return 0;
    uint32_t available = atomic_load_explicit(&context->rxConsumeCount, memory_order_acquire);
    uint32_t take = available < frameCount ? available : frameCount;
    uint32_t pos = context->rxConsumeReadPos;
    for (uint32_t f = 0; f < take; f++) {
        uint32_t idx = ((pos + f) % JARVIS_PCM_TX_RING_FRAMES) * JARVIS_PCM_CHANNEL_COUNT;
        interleaved[f * JARVIS_PCM_CHANNEL_COUNT] = context->rxConsume[idx];
        interleaved[f * JARVIS_PCM_CHANNEL_COUNT + 1] = context->rxConsume[idx + 1];
    }
    context->rxConsumeReadPos = (pos + take) % JARVIS_PCM_TX_RING_FRAMES;
    if (take > 0) {
        atomic_fetch_sub_explicit(&context->rxConsumeCount, take, memory_order_release);
    }
    return take;
}

bool JarvisPCMRuntimeRequestTone(JarvisPCMRuntimeContext *context, int32_t frameCount) {
    if (context == NULL) return false;
    atomic_store_explicit(&context->toneRequestFrames, frameCount, memory_order_relaxed);
    int32_t expected = 0;
    return atomic_compare_exchange_strong_explicit(&context->toneState, &expected, 1, memory_order_release, memory_order_relaxed);
}

void JarvisPCMRuntimeClearTX(JarvisPCMRuntimeContext *context) {
    if (context == NULL) return;
    atomic_store_explicit(&context->txRingCount, 0, memory_order_relaxed);
    context->txRingWritePos = 0;
    context->txRingReadPos = 0;
}

uint32_t JarvisPCMRuntimeWriteTXFrames(
    JarvisPCMRuntimeContext *context,
    const float *interleaved,
    uint32_t frameCount
) {
    if (context == NULL || interleaved == NULL || frameCount == 0) return 0;
    uint32_t used = atomic_load_explicit(&context->txRingCount, memory_order_acquire);
    uint32_t space = JARVIS_PCM_TX_RING_FRAMES - used;
    uint32_t take = frameCount < space ? frameCount : space;
    uint32_t pos = context->txRingWritePos;
    for (uint32_t f = 0; f < take; f++) {
        uint32_t idx = ((pos + f) % JARVIS_PCM_TX_RING_FRAMES) * JARVIS_PCM_CHANNEL_COUNT;
        context->txRing[idx] = interleaved[f * JARVIS_PCM_CHANNEL_COUNT];
        context->txRing[idx + 1] = interleaved[f * JARVIS_PCM_CHANNEL_COUNT + 1];
    }
    context->txRingWritePos = (pos + take) % JARVIS_PCM_TX_RING_FRAMES;
    atomic_fetch_add_explicit(&context->txRingCount, take, memory_order_release);
    return take;
}

static uint32_t ConsumeTXRing(JarvisPCMRuntimeContext *ctx, float *out, uint32_t frameCount) {
    uint32_t available = atomic_load_explicit(&ctx->txRingCount, memory_order_acquire);
    uint32_t take = available < frameCount ? available : frameCount;
    uint32_t pos = ctx->txRingReadPos;
    for (uint32_t f = 0; f < take; f++) {
        uint32_t idx = ((pos + f) % JARVIS_PCM_TX_RING_FRAMES) * JARVIS_PCM_CHANNEL_COUNT;
        out[f * JARVIS_PCM_CHANNEL_COUNT] = ctx->txRing[idx];
        out[f * JARVIS_PCM_CHANNEL_COUNT + 1] = ctx->txRing[idx + 1];
    }
    ctx->txRingReadPos = (pos + take) % JARVIS_PCM_TX_RING_FRAMES;
    if (take > 0) {
        atomic_fetch_sub_explicit(&ctx->txRingCount, take, memory_order_release);
    }
    return take;
}

void JarvisPCMRuntimeReadMetrics(const JarvisPCMRuntimeContext *context, JarvisPCMMetricsSnapshot *outSnapshot) {
    if (context == NULL || outSnapshot == NULL) return;
    outSnapshot->rxFrames = atomic_load_explicit((_Atomic int64_t *)&context->rxFrames, memory_order_relaxed);
    outSnapshot->rxCallbacks = atomic_load_explicit((_Atomic int64_t *)&context->rxCallbacks, memory_order_relaxed);

    uint32_t meanSquareBits = atomic_load_explicit((_Atomic uint32_t *)&context->rxMeanSquareBits, memory_order_relaxed);
    float meanSquare;
    memcpy(&meanSquare, &meanSquareBits, sizeof(meanSquare));
    outSnapshot->rxMeanSquareLinear = meanSquare;

    uint32_t peakBits = atomic_load_explicit((_Atomic uint32_t *)&context->rxPeakBits, memory_order_relaxed);
    float peak;
    memcpy(&peak, &peakBits, sizeof(peak));
    outSnapshot->rxPeakLinear = peak;

    outSnapshot->rxIOProcInvocations = atomic_load_explicit((_Atomic int64_t *)&context->rxIOProcInvocations, memory_order_relaxed);
    outSnapshot->rxNullInputListCallbacks = atomic_load_explicit((_Atomic int64_t *)&context->rxNullInputListCallbacks, memory_order_relaxed);
    outSnapshot->rxZeroBufferCountCallbacks = atomic_load_explicit((_Atomic int64_t *)&context->rxZeroBufferCountCallbacks, memory_order_relaxed);
    outSnapshot->rxInputBufferCountLast = atomic_load_explicit((_Atomic uint32_t *)&context->rxInputBufferCountLast, memory_order_relaxed);
    outSnapshot->rxNullDataBufferCount = atomic_load_explicit((_Atomic int64_t *)&context->rxNullDataBufferCount, memory_order_relaxed);
    outSnapshot->rxReadableDataBufferCount = atomic_load_explicit((_Atomic int64_t *)&context->rxReadableDataBufferCount, memory_order_relaxed);
    outSnapshot->rxReadableNonZeroBufferCount = atomic_load_explicit((_Atomic int64_t *)&context->rxReadableNonZeroBufferCount, memory_order_relaxed);
    outSnapshot->rxOverflowCount = atomic_load_explicit((_Atomic int64_t *)&context->rxOverflowCount, memory_order_relaxed);

    outSnapshot->txFrames = atomic_load_explicit((_Atomic int64_t *)&context->txFrames, memory_order_relaxed);
    outSnapshot->txCallbacks = atomic_load_explicit((_Atomic int64_t *)&context->txCallbacks, memory_order_relaxed);
    outSnapshot->txUnderrunCount = atomic_load_explicit((_Atomic int64_t *)&context->txUnderrunCount, memory_order_relaxed);
    outSnapshot->txQueuedFrames = atomic_load_explicit((_Atomic uint32_t *)&context->txRingCount, memory_order_acquire);
    outSnapshot->toneState = atomic_load_explicit((_Atomic int32_t *)&context->toneState, memory_order_acquire);
}

bool JarvisPCMRuntimeAtomicsAreLockFree(void) {
    JarvisPCMRuntimeContext probe; /* stack-allocated; this function is control-plane only */
    return atomic_is_lock_free(&probe.rxFrames)
        && atomic_is_lock_free(&probe.rxCallbacks)
        && atomic_is_lock_free(&probe.rxMeanSquareBits)
        && atomic_is_lock_free(&probe.rxPeakBits)
        && atomic_is_lock_free(&probe.rxIOProcInvocations)
        && atomic_is_lock_free(&probe.rxNullInputListCallbacks)
        && atomic_is_lock_free(&probe.rxZeroBufferCountCallbacks)
        && atomic_is_lock_free(&probe.rxInputBufferCountLast)
        && atomic_is_lock_free(&probe.rxNullDataBufferCount)
        && atomic_is_lock_free(&probe.rxReadableDataBufferCount)
        && atomic_is_lock_free(&probe.rxReadableNonZeroBufferCount)
        && atomic_is_lock_free(&probe.txFrames)
        && atomic_is_lock_free(&probe.txCallbacks)
        && atomic_is_lock_free(&probe.txUnderrunCount)
        && atomic_is_lock_free(&probe.toneState)
        && atomic_is_lock_free(&probe.toneRequestFrames)
        && atomic_is_lock_free(&probe.txRingCount)
        && atomic_is_lock_free(&probe.rxConsumeCount)
        && atomic_is_lock_free(&probe.rxOverflowCount);
}

/* MARK: - Real-time callbacks (§30 - no malloc/calloc/realloc/free, no Objective-C messaging, no
   Swift invocation, no locks of any kind, no file/network I/O, no logging, no sleeps; only
   bounded local math and the lock-free atomic helpers above) */

static void FillSilence(AudioBufferList *bufferList) {
    if (bufferList == NULL) return;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
        AudioBuffer *buffer = &bufferList->mBuffers[i];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

OSStatus JarvisPCMCaptureIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
) {
    (void)inDevice; (void)inNow; (void)inInputTime; (void)inOutputTime;

    /* Real-device RX-metrics investigation fix: read and record inInputData BEFORE touching
       outOutputData at all. AudioDeviceIOProc's documented contract does not guarantee
       inInputData and outOutputData never share underlying memory for a single-callback
       full-duplex device whose Input and Output streams have an identical format/byte size
       (true here: both are 48kHz Float32 stereo) - if they ever do alias on some real host,
       zeroing outOutputData first would destroy the very samples this callback is about to read
       as RX, producing exactly "callbacks/frames increment but RX signal is always exactly
       zero" despite the driver's own diagnostics showing real non-zero PCM one stage earlier.
       Reordering costs nothing when the buffers are genuinely separate (every existing synthetic
       test already covers that case) and removes the aliased-buffer failure mode entirely either
       way. */
    JarvisPCMRuntimeContext *ctx = (JarvisPCMRuntimeContext *)inClientData;
    if (ctx != NULL) {
        /* RX IOProc stream usage / input buffer delivery investigation (§10-12) - this callback
           ran at all, unconditionally, regardless of what inInputData turns out to be. */
        atomic_fetch_add_explicit(&ctx->rxIOProcInvocations, 1, memory_order_relaxed);

        if (inInputData == NULL) {
            atomic_fetch_add_explicit(&ctx->rxNullInputListCallbacks, 1, memory_order_relaxed);
        } else {
            atomic_store_explicit(&ctx->rxInputBufferCountLast, inInputData->mNumberBuffers, memory_order_relaxed);
            if (inInputData->mNumberBuffers == 0) {
                atomic_fetch_add_explicit(&ctx->rxZeroBufferCountCallbacks, 1, memory_order_relaxed);
            }

            for (UInt32 i = 0; i < inInputData->mNumberBuffers; i++) {
                const AudioBuffer *buffer = &inInputData->mBuffers[i];
                if (buffer->mData == NULL) {
                    atomic_fetch_add_explicit(&ctx->rxNullDataBufferCount, 1, memory_order_relaxed);
                    continue;
                }
                if (buffer->mDataByteSize == 0) continue;
                UInt32 floatCount = buffer->mDataByteSize / (UInt32)sizeof(Float32);
                if (floatCount == 0) continue;
                PublishRXInterleaved(ctx, (const Float32 *)buffer->mData, floatCount);
            }
        }
    }

    /* Capture's own OUTPUT side is not ours to fill - never leave it holding stale memory. Done
       LAST, strictly after every read of inInputData above has already completed. */
    FillSilence(outOutputData);

    return noErr;
}

OSStatus JarvisPCMCaptureAUInputCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) {
    (void)ioData; (void)ioActionFlags; (void)inTimeStamp; (void)inBusNumber;
    JarvisPCMRuntimeContext *ctx = (JarvisPCMRuntimeContext *)inRefCon;
    if (ctx == NULL) return kAudioUnitErr_Uninitialized;
    atomic_fetch_add_explicit(&ctx->rxIOProcInvocations, 1, memory_order_relaxed);

    if (inNumberFrames == 0 || inNumberFrames > JARVIS_PCM_CAPTURE_RENDER_MAX_FRAMES) {
        atomic_fetch_add_explicit(&ctx->rxZeroBufferCountCallbacks, 1, memory_order_relaxed);
        return noErr;
    }

    if (JarvisCaptureRXRingIsMapped(ctx->rxRing) && ctx->captureRenderFrames != NULL) {
        const uint32_t floatCount = inNumberFrames * (UInt32)JARVIS_PCM_CHANNEL_COUNT;
        if (ctx->rxRingRequireWriteAdvance
            && JarvisCaptureRXRingWriteIndex(ctx->rxRing) <= ctx->rxRingWriteIndexAtArm) {
            memset(ctx->captureRenderFrames, 0, (size_t)floatCount * sizeof(float));
            atomic_store_explicit(&ctx->rxInputBufferCountLast, 1, memory_order_relaxed);
            PublishRXInterleaved(ctx, ctx->captureRenderFrames, floatCount);
            return noErr;
        }
        JarvisCaptureRXRingTapLatest(ctx->rxRing, ctx->captureRenderFrames, inNumberFrames);
        atomic_store_explicit(&ctx->rxInputBufferCountLast, 1, memory_order_relaxed);
        PublishRXInterleaved(ctx, ctx->captureRenderFrames, floatCount);
        return noErr;
    }

    if (ctx->captureAudioUnit == NULL || ctx->captureRenderFrames == NULL) {
        atomic_fetch_add_explicit(&ctx->rxNullInputListCallbacks, 1, memory_order_relaxed);
        return kAudioUnitErr_Uninitialized;
    }

    /* HAL ReadInput for this extra client is always silence. Do not AudioUnitRender it. */
    atomic_fetch_add_explicit(&ctx->rxNullDataBufferCount, 1, memory_order_relaxed);
    return noErr;
}

OSStatus JarvisPCMProcessTapAUInputCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) {
    (void)ioData;
    JarvisPCMRuntimeContext *ctx = (JarvisPCMRuntimeContext *)inRefCon;
    if (ctx == NULL) return kAudioUnitErr_Uninitialized;
    atomic_fetch_add_explicit(&ctx->rxIOProcInvocations, 1, memory_order_relaxed);

    if (inNumberFrames == 0 || inNumberFrames > JARVIS_PCM_CAPTURE_RENDER_MAX_FRAMES) {
        atomic_fetch_add_explicit(&ctx->rxZeroBufferCountCallbacks, 1, memory_order_relaxed);
        return noErr;
    }
    if (ctx->captureAudioUnit == NULL || ctx->captureRenderFrames == NULL) {
        atomic_fetch_add_explicit(&ctx->rxNullInputListCallbacks, 1, memory_order_relaxed);
        return kAudioUnitErr_Uninitialized;
    }

    const UInt32 floatCount = inNumberFrames * (UInt32)JARVIS_PCM_CHANNEL_COUNT;
    AudioBufferList abl;
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = (UInt32)JARVIS_PCM_CHANNEL_COUNT;
    abl.mBuffers[0].mDataByteSize = floatCount * (UInt32)sizeof(float);
    abl.mBuffers[0].mData = ctx->captureRenderFrames;

    OSStatus status = AudioUnitRender(
        ctx->captureAudioUnit,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        &abl
    );
    if (status != noErr) {
        atomic_fetch_add_explicit(&ctx->rxNullDataBufferCount, 1, memory_order_relaxed);
        return status;
    }

    atomic_store_explicit(&ctx->rxInputBufferCountLast, 1, memory_order_relaxed);
    PublishRXInterleaved(ctx, ctx->captureRenderFrames, floatCount);
    return noErr;
}

OSStatus JarvisPCMInjectIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
) {
    (void)inDevice; (void)inNow; (void)inInputData; (void)inInputTime; (void)inOutputTime;

    JarvisPCMRuntimeContext *ctx = (JarvisPCMRuntimeContext *)inClientData;
    if (ctx == NULL) {
        FillSilence(outOutputData);
        return noErr;
    }
    if (outOutputData == NULL) return noErr;

    for (UInt32 i = 0; i < outOutputData->mNumberBuffers; i++) {
        AudioBuffer *buffer = &outOutputData->mBuffers[i];
        if (buffer->mData == NULL || buffer->mDataByteSize == 0) {
            RecordTXUnderrun(ctx); /* malformed buffer - nothing we could write */
            continue;
        }
        UInt32 floatCount = buffer->mDataByteSize / (UInt32)sizeof(Float32);
        if (floatCount == 0) continue;
        Float32 *samples = (Float32 *)buffer->mData;
        int64_t frameCount = (int64_t)(floatCount / JARVIS_PCM_CHANNEL_COUNT);

        uint32_t copied = ConsumeTXRing(ctx, samples, (uint32_t)frameCount);
        if (copied < (uint32_t)frameCount) {
            memset(
                samples + copied * JARVIS_PCM_CHANNEL_COUNT,
                0,
                (size_t)(frameCount - (int64_t)copied) * JARVIS_PCM_CHANNEL_COUNT * sizeof(Float32)
            );
        }

        if (ctx->toneFramesRemaining <= 0 && copied > 0) {
            int32_t requested = 0;
            if (PollQueuedToneRequest(ctx, &requested)) {
                ctx->toneFramesRemaining = requested;
            }
        }
        if (ctx->toneFramesRemaining > 0) {
            int64_t consumed = (int64_t)copied < ctx->toneFramesRemaining
                ? (int64_t)copied
                : ctx->toneFramesRemaining;
            ctx->toneFramesRemaining -= consumed;
            if (ctx->toneFramesRemaining == 0) {
                MarkToneComplete(ctx);
            }
        }

        int32_t toneNow = atomic_load_explicit(&ctx->toneState, memory_order_acquire);
        if (copied < (uint32_t)frameCount && (toneNow == 1 || toneNow == 2)) {
            RecordTXUnderrun(ctx);
        }

        RecordTX(ctx, frameCount);
    }

    return noErr;
}
