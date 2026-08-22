#ifndef JARVIS_PCM_REALTIME_H
#define JARVIS_PCM_REALTIME_H

#include <AudioToolbox/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

/*
 * Phase 3 CHECKPOINT 2 - C Native IOProc Real-Time Hardening.
 *
 * The previous design (a Swift AudioDeviceIOBlock calling C11-atomic-backed Swift functions)
 * removed all blocking synchronization from the callback path, but Swift code still executed on
 * the real-time audio thread on every single IO cycle. This target now owns the ENTIRE
 * production callback: CoreAudio calls JarvisPCMCaptureIOProc/JarvisPCMInjectIOProc directly as
 * plain C function pointers (registered via AudioDeviceCreateIOProcID, not the block-based
 * AudioDeviceCreateIOProcIDWithBlock), and neither one calls back into Swift, allocates, locks,
 * logs, or does any I/O. Swift's SystemCallAudioPCMController is reduced to a pure control-plane
 * orchestrator: it resolves devices, validates format, registers/starts/stops these C callbacks,
 * and periodically (5Hz, non-real-time) reads a snapshot for the UI.
 *
 * Context lifetime contract (see SystemCallAudioPCMController.swift for the actual call sites):
 *   1. JarvisPCMRuntimeCreate()            - control plane, before any IOProc exists
 *   2. AudioDeviceCreateIOProcID(...)       - control plane, registers the C callbacks above
 *   3. AudioDeviceStart(...)                - control plane; only from here on can a callback run
 *   4. (callbacks execute, owning/reading only the context below)
 *   5. AudioDeviceStop(...)                 - control plane; CoreAudio guarantees no further
 *                                              callback invocation once this returns
 *   6. AudioDeviceDestroyIOProcID(...)       - control plane
 *   7. JarvisPCMRuntimeDestroy()             - control plane; only after BOTH IOProcs (Capture
 *                                              and Inject) have completed steps 5-6 - the context
 *                                              must never be freed while a callback could still
 *                                              be executing or about to be invoked.
 *
 * Ownership split inside the context:
 *   - The RX and TX counter fields are single-writer atomics - only the respective real-time
 *     callback ever writes them (RX by Capture's, TX by Inject's), read only by the
 *     non-real-time 5Hz UI snapshot. Relaxed ordering is sufficient - nothing here needs to be
 *     causally ordered with anything else.
 *   - toneState/toneRequestFrames: the one genuinely multi-writer-adjacent handoff - the
 *     non-real-time "send test tone" action publishes a request (idle to queued via a single
 *     compare-exchange, so a second concurrent request cannot also win); the Inject real-time
 *     callback is the sole consumer. Release/acquire ordering guarantees the callback that
 *     observes toneState == 1 also observes the toneRequestFrames value stored immediately
 *     before it.
 *   - toneFramesRemaining: callback-owned consume countdown. The Inject IOProc decrements it
 *     as it reads frames from the TX ring while a tone is queued/playing. Sine generation and
 *     phase live on the non-real-time producer (WriteTXFrames), not inside the callback.
 *   - txRing: SPSC lock-free stereo Float32 ring. WriteTXFrames is the sole producer;
 *     Inject IOProc is the sole consumer.
 *
 * Fixed contract this runtime is built against (validated by Swift BEFORE any IOProc is
 * registered - see CallAudioPCMFormat.expected in SystemCallAudioPCMController.swift): 48000 Hz,
 * Float32, 2 channels, interleaved. A mismatch fails PCM startup safely; this runtime never
 * resamples or adapts to a different format.
 */

#define JARVIS_PCM_CHANNEL_COUNT 2
#define JARVIS_PCM_SAMPLE_RATE 48000.0
#define JARVIS_PCM_TONE_FREQUENCY_HZ 1000.0
#define JARVIS_PCM_TONE_AMPLITUDE 0.1f
#define JARVIS_PCM_CAPTURE_RENDER_MAX_FRAMES 8192
#define JARVIS_PCM_TX_RING_FRAMES 48000

/* Opaque to Swift on purpose (§10 - "do not expose raw internal atomics to Swift"): only this
   translation unit ever sees the full struct definition and its atomic fields. Swift holds and
   passes around nothing but the pointer. */
typedef struct JarvisPCMRuntimeContext JarvisPCMRuntimeContext;

/* A point-in-time, intentionally eventually-consistent snapshot (§7/§32) - never itself atomic,
   just a plain copy-out for the non-real-time reader. rxMeanSquareLinear/rxPeakLinear are linear
   (not dBFS) on purpose (§16): dB conversion is presentation work, done by the Swift 5Hz reader,
   never inside the real-time callback. */
typedef struct {
    int64_t rxFrames;
    int64_t rxCallbacks;
    float rxMeanSquareLinear;
    float rxPeakLinear;
    int64_t txFrames;
    int64_t txCallbacks;
    int64_t txUnderrunCount;
    int32_t toneState; /* 0 = idle, 1 = queued, 2 = playing */

    /* Phase 3 CHECKPOINT 2 RX IOProc stream usage / input buffer delivery investigation.
       Distinguishes exactly where in "CoreAudio -> JarvisPCMCaptureIOProc" a real call's PCM
       could stop being readable, without ever storing raw PCM:
         - rxIOProcInvocations: the callback ran at all (baseline - increments once per call,
           unconditionally, regardless of inInputData).
         - rxNullInputListCallbacks: inInputData itself was NULL this invocation.
         - rxZeroBufferCountCallbacks: inInputData was non-NULL but mNumberBuffers == 0.
         - rxInputBufferCountLast: mNumberBuffers observed on the most recent invocation that had
           a non-NULL inInputData (not cumulative - a live "what does CoreAudio actually hand us"
           reading).
         - rxNullDataBufferCount: cumulative count of individual AudioBuffers seen with
           mData == NULL (per AudioHardwareIOProcStreamUsage's documented contract, this is what a
           disabled/unused stream looks like to an IOProc).
         - rxReadableDataBufferCount: cumulative count of individual AudioBuffers seen with
           mData != NULL && mDataByteSize > 0 - i.e. buffers CoreAudio actually delivered as
           readable, whatever their content. Under the current implementation this is always
           exactly rxCallbacks (both increment together, from the same guarded code path) - kept
           as a separately-named field so that fact is verified by a snapshot reading, not assumed.
         - rxReadableNonZeroBufferCount: of those readable buffers, how many had a non-zero peak. */
    int64_t rxIOProcInvocations;
    int64_t rxNullInputListCallbacks;
    int64_t rxZeroBufferCountCallbacks;
    uint32_t rxInputBufferCountLast;
    int64_t rxNullDataBufferCount;
    int64_t rxReadableDataBufferCount;
    int64_t rxReadableNonZeroBufferCount;
} JarvisPCMMetricsSnapshot;

/* MARK: - Control plane (non-real-time only; never called from a callback) */

CF_ASSUME_NONNULL_BEGIN

/* Allocates and fully resets a new context. Returns NULL on allocation failure. */
JarvisPCMRuntimeContext *_Nullable JarvisPCMRuntimeCreate(void);

/* Resets every counter and the tone state machine to its starting value. Caller must guarantee
   this is never called while a callback could be concurrently executing (§11/§19) - i.e. only
   before IOProc registration, or after both IOProcs have been fully stopped and destroyed. */
void JarvisPCMRuntimeReset(JarvisPCMRuntimeContext *context);

/* Frees the context. Caller must guarantee both the Capture and Inject IOProcs have already been
   stopped (AudioDeviceStop) and destroyed (AudioDeviceDestroyIOProcID) - CoreAudio's own
   contract guarantees no further callback invocation once AudioDeviceStop has returned, which is
   what makes it safe to free the memory a callback would otherwise still be reading. Safe to
   call with NULL (no-op). */
void JarvisPCMRuntimeDestroy(JarvisPCMRuntimeContext *_Nullable context);

/* Publishes a new tone request via a single compare-exchange (idle -> queued). Returns false,
   without any effect, if a tone is already queued or playing (§21 - "reject while already
   playing/queued" policy, preserved exactly). */
bool JarvisPCMRuntimeRequestTone(JarvisPCMRuntimeContext *context, int32_t frameCount);

/* Control plane. Writes up to frameCount interleaved stereo Float32 frames.
   Returns frames actually stored. Never blocks. */
uint32_t JarvisPCMRuntimeWriteTXFrames(
    JarvisPCMRuntimeContext *context,
    const float *interleaved,
    uint32_t frameCount
);

/* Control plane after both IOProcs have stopped, or during Reset.
   Drops unread TX. Future barge-in may call this; CP1 does not call it while IOProc runs. */
void JarvisPCMRuntimeClearTX(JarvisPCMRuntimeContext *context);

/* Copies the current state into *outSnapshot. Safe to call at any time, including while IOProcs
   are actively running - never blocks, never allocates. */
void JarvisPCMRuntimeReadMetrics(const JarvisPCMRuntimeContext *context, JarvisPCMMetricsSnapshot *outSnapshot);

/* True if every atomic type this runtime relies on is actually lock-free on the current build
   target (§14). SystemCallAudioPCMController checks this once, before registering any IOProc,
   and fails PCM startup safely if it is ever false - this must never be discovered from inside a
   callback. */
bool JarvisPCMRuntimeAtomicsAreLockFree(void);

/* Stores the AUHAL instance used by JarvisPCMCaptureAUInputCallback and allocates the
   callback-local render scratch (control plane only). Returns false if `audioUnit` is NULL
   or the scratch buffer cannot be allocated. */
bool JarvisPCMRuntimeAttachCaptureAudioUnit(JarvisPCMRuntimeContext *context, AudioUnit audioUnit);

/* Maps `/jarvis-callbridge-capture-rx` for the AUHAL callback to tap. Returns false if shm
   is missing or unreadable — caller should use the Capture `Rrxc` property fallback. */
bool JarvisPCMRuntimeOpenCaptureRXRing(JarvisPCMRuntimeContext *context);

/* Borrows a caller-owned ring (unit tests). Does not close it on Destroy. */
bool JarvisPCMRuntimeAdoptCaptureRXRing(JarvisPCMRuntimeContext *context, void *ring);

/* True after a successful Open/Adopt. */
bool JarvisPCMRuntimeCaptureRXRingIsMapped(const JarvisPCMRuntimeContext *context);

/* After Open/Adopt, treat the current writeIndex as leftover. AUHAL publishes silence
   until the producer advances. Same-call evidence: Bridge opened a leftover shm whose
   writeIndex never moved while Capture WriteMix (peak ~0.01) went only to the HAL loopback. */
void JarvisPCMRuntimeArmCaptureRXRingProducerCheck(JarvisPCMRuntimeContext *context);

/* Current shm writeIndex, or 0 if unmapped. */
uint64_t JarvisPCMRuntimeCaptureRXRingWriteIndex(const JarvisPCMRuntimeContext *context);

/* False only while a producer check is armed and writeIndex has not moved. */
bool JarvisPCMRuntimeCaptureRXRingProducerHasAdvanced(const JarvisPCMRuntimeContext *context);

/* Drop a stale shm mapping so the Rrxc fallback can take over. */
void JarvisPCMRuntimeCloseCaptureRXRing(JarvisPCMRuntimeContext *context);

/* Control-plane ingest for the `Rrxc` fallback poller. Same PublishRX path as the callback. */
void JarvisPCMRuntimePublishRXFrames(JarvisPCMRuntimeContext *context, const float *samples, uint32_t frameCount);

CF_ASSUME_NONNULL_END

/* MARK: - Real-time (CoreAudio calls these directly via AudioDeviceCreateIOProcID; Swift never
   calls them, and they never call back into Swift - see the file-level doc comment)

   Wrapped in CF_ASSUME_NONNULL_BEGIN/END, exactly like AudioHardware.h's own AudioDeviceIOProc
   declaration - without it, Clang's importer treats every unannotated pointer parameter here as
   having "unspecified" nullability and imports it into Swift as Optional, which then fails to
   match AudioDeviceIOProc's (non-Optional-pointer) expected type at the AudioDeviceCreateIOProcID
   call site. inClientData is the one parameter genuinely allowed to be NULL, so it alone is
   marked _Nullable within the block. */
CF_ASSUME_NONNULL_BEGIN

/* The native Capture AudioDeviceIOProc. inClientData must be a JarvisPCMRuntimeContext* returned
   by JarvisPCMRuntimeCreate. Reads Capture's INPUT buffer (the real caller/Phone.app audio,
   delivered via the driver's own loopback), publishes aggregate RX metrics once per callback,
   and fully zeroes Capture's OUTPUT buffer (nothing of Jarvis's belongs there). */
OSStatus JarvisPCMCaptureIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *_Nullable inClientData
);

/* AUHAL input callback for Capture RX. CoreAudio invokes this as a real input client of the
   Capture device (unlike an extra AudioDeviceIOProc attached to the same device after it became
   default output, which the host may fire with silent inInputData and never call plugin
   ReadInput). `ioData` is typically NULL — the callback AudioUnitRenders into runtime scratch. */
OSStatus JarvisPCMCaptureAUInputCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *_Nullable ioData
);

/* The native Inject AudioDeviceIOProc. inClientData must be a JarvisPCMRuntimeContext*. Always
   fully initializes Inject's OUTPUT buffer from the TX ring, or to digital silence when the
   ring is empty. Never synthesizes the test tone. */
OSStatus JarvisPCMInjectIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *_Nullable inClientData
);

CF_ASSUME_NONNULL_END

#endif /* JARVIS_PCM_REALTIME_H */
