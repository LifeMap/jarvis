#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#include "PlugInTypes.h"

/*
 * CB v2 Phase 1 in-process self-test. dlopen()s the built JarvisCallAudio.driver bundle Mach-O
 * directly and exercises the factory function, QueryInterface, and property dispatch for BOTH
 * devices — without coreaudiod, without sudo, without installing anything. Proves "the vtable
 * links and the two-device/four-stream object model answers property queries correctly", a
 * distinct, weaker claim than "coreaudiod actually loaded it" (needs install-driver.sh, not run
 * here) or "a real client can loop audio through it" (needs JarvisAudioDriverTool against an
 * installed driver).
 */

typedef void *(*FactoryFunc)(CFAllocatorRef, CFUUIDRef);

static int gFailures = 0;
static int gPropertiesChangedCallCount = 0;
static AudioObjectID gLastPropertiesChangedObjectID = 0;
static Boolean gLastChangeIncludedCanBeDefaultDevice = false;

/* Real coreaudiod always supplies a fully-formed AudioServerPlugInHostInterface — every function
   pointer valid — so the dummy host below must too, rather than being all-zero. The driver now
   calls back into PropertiesChanged() when Active toggles (see PlugInInterface.c); a null function
   pointer there would crash exactly like it did on the real Mac's coreaudiod-hosted copy before
   this stub existed to catch it in-process. */
static OSStatus StubPropertiesChanged(AudioServerPlugInHostRef inHost, AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses) {
    (void)inHost;
    gPropertiesChangedCallCount++;
    gLastPropertiesChangedObjectID = inObjectID;
    gLastChangeIncludedCanBeDefaultDevice = false;
    for (UInt32 i = 0; i < inNumberAddresses; i++) {
        if (inAddresses[i].mSelector == kAudioDevicePropertyDeviceCanBeDefaultDevice) gLastChangeIncludedCanBeDefaultDevice = true;
    }
    return kAudioHardwareNoError;
}

static void Check(const char *label, int condition) {
    if (condition) {
        printf("PASS: %s\n", label);
    } else {
        printf("FAIL: %s\n", label);
        gFailures++;
    }
}

static void PrintCFString(const char *label, CFStringRef value) {
    if (value == NULL) { printf("  %s = (null)\n", label); return; }
    char buffer[256];
    if (CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        printf("  %s = %s\n", label, buffer);
    } else {
        printf("  %s = (unreadable CFString)\n", label);
    }
}

/* Real CF ownership investigation (§7/§8) — models the documented "caller releases" contract
   (AudioServerPlugIn.h's CopyFromStorage: "the caller is responsible for releasing the returned
   CFObject", the only explicit ownership language anywhere in this header for CFPropertyList
   values crossing this exact boundary). Driver_GetPropertyData(Rpcm) now returns a freshly
   created, single-owner CFDataRef per call — this releases it after decoding, exactly as a
   correctly-behaving real caller would. This is what makes 100-iteration/concurrent-read
   selftests below a meaningful reproduction of the real-device failure mode, not just "the
   in-process vtable call happens to still work". */
static Boolean ReadPCMDiagnostics(AudioServerPlugInDriverInterface *interface, AudioServerPlugInDriverRef driverRef, AudioObjectID deviceID, JarvisPCMDeviceDiagnostics *outSnapshot) {
    AudioObjectPropertyAddress address = { kJarvisDevicePropertyPCMDiagnostics, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFTypeRef value = NULL;
    UInt32 outSize = 0;
    OSStatus status = interface->GetPropertyData(driverRef, deviceID, 0, &address, 0, NULL, sizeof(value), &outSize, &value);
    if (status != kAudioHardwareNoError || value == NULL) return false;
    if (CFGetTypeID(value) != CFDataGetTypeID()) { CFRelease(value); return false; }
    CFDataRef data = (CFDataRef)value;
    Boolean sizeOk = (size_t)CFDataGetLength(data) >= sizeof(JarvisPCMDeviceDiagnostics);
    if (sizeOk) memcpy(outSnapshot, CFDataGetBytePtr(data), sizeof(JarvisPCMDeviceDiagnostics));
    CFRelease(data);
    return sizeOk;
}

/* §13 investigation — plain pthread entry point (NOT a Clang block; blocks are not
   function-pointer-ABI-compatible with pthread_create) for the concurrent Rpcm read stress
   test below. */
typedef struct {
    AudioServerPlugInDriverInterface *interface;
    AudioServerPlugInDriverRef driverRef;
    AudioObjectID deviceID;
    int successCount;
} ConcurrentPCMReadArgs;

static void *ConcurrentPCMRead(void *rawArgs) {
    ConcurrentPCMReadArgs *args = (ConcurrentPCMReadArgs *)rawArgs;
    for (int i = 0; i < 200; i++) {
        JarvisPCMDeviceDiagnostics snapshot;
        if (ReadPCMDiagnostics(args->interface, args->driverRef, args->deviceID, &snapshot) && snapshot.version == 1) {
            args->successCount++;
        }
    }
    return NULL;
}

/* Phase 3 CHECKPOINT 2 RX investigation (§13/§22-23/§32-36) — exercises the exact real path a
   live call uses: a client WriteMix with known Float32 stereo data, then the very next ReadInput
   on the SAME device, verified byte-for-byte through the loopback — not an isolated ring-buffer
   test. Also proves the diagnostics property itself: starts at zero after reset, increments
   correctly for both zero and non-zero PCM, and is read-only. */
static void CheckPCMDiagnostics(AudioServerPlugInDriverInterface *interface, AudioServerPlugInDriverRef driverRef, AudioObjectID deviceID, AudioObjectID outputStreamID, AudioObjectID inputStreamID) {
    (void)outputStreamID; (void)inputStreamID; // DoIOOperation dispatches by inDeviceObjectID, not stream ID (see PlugInInterface.c)
    // The DoIOOperation vtable slot declares inIOCycleInfo non-null (Driver_DoIOOperation itself
    // never dereferences it, but the SDK's own nullability annotation still requires a real
    // pointer here, not a literal NULL).
    AudioServerPlugInIOCycleInfo dummyCycleInfo;
    memset(&dummyCycleInfo, 0, sizeof(dummyCycleInfo));

    // Read-only enforcement: Set must fail, never silently succeed.
    AudioObjectPropertyAddress diagAddress = { kJarvisDevicePropertyPCMDiagnostics, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Boolean settable = true;
    interface->IsPropertySettable(driverRef, deviceID, 0, &diagAddress, &settable);
    Check("PCM diagnostics IsPropertySettable == false", settable == false);
    CFTypeRef bogusValue = kCFBooleanTrue;
    OSStatus setStatus = interface->SetPropertyData(driverRef, deviceID, 0, &diagAddress, 0, NULL, sizeof(bogusValue), &bogusValue);
    Check("PCM diagnostics SetPropertyData is rejected", setStatus != kAudioHardwareNoError);

    // §26/§29 investigation — exact GetPropertyDataSize/GetPropertyData contract, not just "a
    // read eventually succeeds". The reported size is a CFTypeRef handle (pointer), not
    // sizeof(JarvisPCMDeviceDiagnostics) — the actual struct bytes travel inside the CFData the
    // handle points to, marshaled separately by CoreFoundation/XPC, exactly mirroring the
    // already-real-device-proven kJarvisDevicePropertyActive pattern.
    UInt32 diagSize = 0;
    OSStatus sizeStatus = interface->GetPropertyDataSize(driverRef, deviceID, 0, &diagAddress, 0, NULL, &diagSize);
    Check("PCM diagnostics GetPropertyDataSize succeeds", sizeStatus == kAudioHardwareNoError);
    Check("PCM diagnostics GetPropertyDataSize == sizeof(CFTypeRef)", diagSize == (UInt32)sizeof(CFTypeRef));

    CFTypeRef undersizedOut = NULL;
    UInt32 undersizedOutSize = 0;
    OSStatus undersizedStatus = interface->GetPropertyData(driverRef, deviceID, 0, &diagAddress, 0, NULL, (UInt32)sizeof(CFTypeRef) - 1, &undersizedOutSize, &undersizedOut);
    Check("PCM diagnostics GetPropertyData rejects an undersized buffer", undersizedStatus == kAudioHardwareBadPropertySizeError);

    // ClearBuffers also resets PCM diagnostics (mirrors JarvisLoopbackBufferReset's call site) —
    // use it to guarantee a known zero baseline regardless of what earlier checks in this device
    // already did via DoIOOperation.
    AudioObjectPropertyAddress clearAddress = { kJarvisDevicePropertyClearBuffers, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFTypeRef triggerValue = kCFBooleanFalse;
    interface->SetPropertyData(driverRef, deviceID, 0, &clearAddress, 0, NULL, sizeof(triggerValue), &triggerValue);

    JarvisPCMDeviceDiagnostics snapshot;
    Boolean ok = ReadPCMDiagnostics(interface, driverRef, deviceID, &snapshot);
    Check("PCM diagnostics readable", ok);
    if (ok) {
        Check("PCM diagnostics version == 1", snapshot.version == 1);
        Check("PCM diagnostics start at zero after reset", snapshot.outputOperationCount == 0 && snapshot.outputFrames == 0 && snapshot.outputNonZeroCallbacks == 0 &&
              snapshot.inputOperationCount == 0 && snapshot.inputFrames == 0 && snapshot.inputNonZeroCallbacks == 0 &&
              snapshot.loopbackWriteFrames == 0 && snapshot.loopbackReadFrames == 0);
    }

    // Non-zero path: WriteMix a known 64-frame/2ch tone, then ReadInput the same frame count on
    // the SAME device — this is the exact client-write -> DoIOOperation -> loopback -> client-read
    // path a real call uses, verified byte-for-byte, not just "the ring buffer works in isolation".
    const UInt32 frameCount = 64;
    const UInt32 channels = 2;
    float writeBuffer[64 * 2];
    for (UInt32 i = 0; i < frameCount * channels; i++) writeBuffer[i] = 0.25f + (float)i * 0.001f;

    OSStatus writeStatus = interface->DoIOOperation(driverRef, deviceID, outputStreamID, 0, kAudioServerPlugInIOOperationWriteMix, frameCount, &dummyCycleInfo, writeBuffer, NULL);
    Check("DoIOOperation(WriteMix, non-zero) succeeds", writeStatus == kAudioHardwareNoError);

    float readBuffer[64 * 2];
    memset(readBuffer, 0, sizeof(readBuffer));
    OSStatus readStatus = interface->DoIOOperation(driverRef, deviceID, inputStreamID, 0, kAudioServerPlugInIOOperationReadInput, frameCount, &dummyCycleInfo, readBuffer, NULL);
    Check("DoIOOperation(ReadInput) succeeds", readStatus == kAudioHardwareNoError);
    Check("ReadInput returns byte-for-byte what WriteMix wrote (real loopback path)", memcmp(writeBuffer, readBuffer, sizeof(writeBuffer)) == 0);

    if (deviceID == kJarvisCallAudio_Capture_Device) {
        AudioObjectPropertyAddress chunkAddress = { kJarvisDevicePropertyCaptureRXChunk, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        CFTypeRef chunkObject = NULL;
        UInt32 chunkOut = 0;
        OSStatus chunkStatus = interface->GetPropertyData(driverRef, deviceID, 0, &chunkAddress, 0, NULL, sizeof(chunkObject), &chunkOut, &chunkObject);
        Check("Capture RX chunk GetPropertyData succeeds after WriteMix", chunkStatus == kAudioHardwareNoError && chunkObject != NULL);
        if (chunkStatus == kAudioHardwareNoError && chunkObject != NULL && CFGetTypeID(chunkObject) == CFDataGetTypeID()) {
            CFDataRef chunkData = (CFDataRef)chunkObject;
            Check("Capture RX chunk CFData size matches struct", CFDataGetLength(chunkData) == (CFIndex)sizeof(JarvisCaptureRXFallbackChunk));
            JarvisCaptureRXFallbackChunk chunk;
            memcpy(&chunk, CFDataGetBytePtr(chunkData), sizeof(chunk));
            Check("Capture RX chunk version == 1", chunk.version == 1);
            Check("Capture RX chunk frameCount == WriteMix frames", chunk.frameCount == frameCount);
            Check("Capture RX chunk samples match WriteMix", memcmp(chunk.samples, writeBuffer, sizeof(writeBuffer)) == 0);
            CFRelease(chunkObject);
        }

        JarvisCaptureRXRing ring;
        if (JarvisCaptureRXRingOpen(&ring)) {
            float tapped[64 * 2];
            memset(tapped, 0, sizeof(tapped));
            JarvisCaptureRXRingTapLatest(&ring, tapped, frameCount);
            Check("Capture RX shm tap matches WriteMix", memcmp(tapped, writeBuffer, sizeof(writeBuffer)) == 0);
            JarvisCaptureRXRingClose(&ring);
        } else {
            Check("Capture RX shm opens after driver Initialize+WriteMix", false);
        }
    }

    ok = ReadPCMDiagnostics(interface, driverRef, deviceID, &snapshot);
    Check("PCM diagnostics readable after non-zero IO", ok);
    if (ok) {
        Check("outputOperationCount == 1 after one WriteMix", snapshot.outputOperationCount == 1);
        Check("outputFrames == frameCount after one WriteMix", snapshot.outputFrames == (int64_t)frameCount);
        Check("outputNonZeroCallbacks == 1 for non-zero WriteMix", snapshot.outputNonZeroCallbacks == 1);
        Check("outputPeakLinear > 0 for non-zero WriteMix", snapshot.outputPeakLinear > 0.0f);
        Check("loopbackWriteFrames == frameCount", snapshot.loopbackWriteFrames == (uint64_t)frameCount);
        Check("loopbackReadFrames == 0 (ReadInput taps and does not drain)", snapshot.loopbackReadFrames == 0);
        Check("inputOperationCount == 1 after one ReadInput", snapshot.inputOperationCount == 1);
        Check("inputFrames == frameCount after one ReadInput", snapshot.inputFrames == (int64_t)frameCount);
        Check("inputNonZeroCallbacks == 1 for non-zero ReadInput", snapshot.inputNonZeroCallbacks == 1);
        Check("inputPeakLinear > 0 for non-zero ReadInput", snapshot.inputPeakLinear > 0.0f);
        Check("ioClientCount == 0 (no AudioDeviceStart in this in-process test)", snapshot.ioClientCount == 0);
    }

    /* Non-in-place host contract: results must also land in ioSecondaryBuffer when it is provided. */
    float writeBuffer2[64 * 2];
    memcpy(writeBuffer2, writeBuffer, sizeof(writeBuffer2));
    interface->DoIOOperation(driverRef, deviceID, outputStreamID, 0, kAudioServerPlugInIOOperationWriteMix, frameCount, &dummyCycleInfo, writeBuffer2, NULL);
    float readMain[64 * 2];
    float readSecondary[64 * 2];
    memset(readMain, 0, sizeof(readMain));
    memset(readSecondary, 0x7F, sizeof(readSecondary));
    OSStatus readBothStatus = interface->DoIOOperation(driverRef, deviceID, inputStreamID, 0, kAudioServerPlugInIOOperationReadInput, frameCount, &dummyCycleInfo, readMain, readSecondary);
    Check("DoIOOperation(ReadInput, secondary buffer) succeeds", readBothStatus == kAudioHardwareNoError);
    Check("ReadInput main buffer matches WriteMix when secondary is also provided", memcmp(writeBuffer2, readMain, sizeof(writeBuffer2)) == 0);
    Check("ReadInput secondary buffer matches WriteMix (host non-in-place contract)", memcmp(writeBuffer2, readSecondary, sizeof(writeBuffer2)) == 0);

    float readAgain[64 * 2];
    memset(readAgain, 0, sizeof(readAgain));
    OSStatus tapAgainStatus = interface->DoIOOperation(driverRef, deviceID, inputStreamID, 0, kAudioServerPlugInIOOperationReadInput, frameCount, &dummyCycleInfo, readAgain, NULL);
    Check("second ReadInput without a new WriteMix succeeds", tapAgainStatus == kAudioHardwareNoError);
    Check("second ReadInput still returns the latest WriteMix (tap, not exclusive drain)", memcmp(writeBuffer2, readAgain, sizeof(writeBuffer2)) == 0);

    // §14/§15/§39 investigation — a read-only diagnostics property must have NO side effects:
    // repeated reads (no further DoIOOperation calls in between) must return byte-identical
    // snapshots every time, and must never change isActive/isHidden/ioClientCount by themselves.
    {
        JarvisPCMDeviceDiagnostics first;
        Boolean firstOk = ReadPCMDiagnostics(interface, driverRef, deviceID, &first);
        Check("PCM diagnostics readable for repeated-read check", firstOk);

        UInt32 activeBeforeAddress_hidden = 0;
        AudioObjectPropertyAddress hiddenCheckAddress = { kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 outSizeUnused;
        interface->GetPropertyData(driverRef, deviceID, 0, &hiddenCheckAddress, 0, NULL, sizeof(activeBeforeAddress_hidden), &outSizeUnused, &activeBeforeAddress_hidden);

        Boolean allIdentical = true;
        for (int i = 0; i < 20; i++) {
            JarvisPCMDeviceDiagnostics repeat;
            Boolean repeatOk = ReadPCMDiagnostics(interface, driverRef, deviceID, &repeat);
            if (!repeatOk || memcmp(&first, &repeat, sizeof(first)) != 0) {
                allIdentical = false;
                break;
            }
        }
        Check("20 repeated PCM diagnostics reads (no intervening IO) are byte-identical — no side effects", allIdentical);

        UInt32 activeAfterAddress_hidden = 0;
        interface->GetPropertyData(driverRef, deviceID, 0, &hiddenCheckAddress, 0, NULL, sizeof(activeAfterAddress_hidden), &outSizeUnused, &activeAfterAddress_hidden);
        Check("repeated PCM diagnostics reads never change IsHidden", activeBeforeAddress_hidden == activeAfterAddress_hidden);
    }

    // §8/§12 investigation — 100 iterations of the FULL realistic property-client sequence
    // (HasProperty -> GetPropertyDataSize -> GetPropertyData -> decode -> release ->
    // HasProperty again), the exact reproduction shape this investigation asked for: this is
    // what would have caught the real-device "works once, then fails every time after" pattern
    // if the pre-fix persistent-CFMutableDataRef design had still been in place, since each
    // iteration here properly releases what it received, exactly like a correctly-behaving
    // real caller.
    {
        int successCount = 0;
        for (int i = 0; i < 100; i++) {
            Boolean hasBefore = interface->HasProperty(driverRef, deviceID, 0, &diagAddress);
            if (!hasBefore) break;

            UInt32 sizeOut = 0;
            OSStatus sizeStatus = interface->GetPropertyDataSize(driverRef, deviceID, 0, &diagAddress, 0, NULL, &sizeOut);
            if (sizeStatus != kAudioHardwareNoError || sizeOut != (UInt32)sizeof(CFTypeRef)) break;

            JarvisPCMDeviceDiagnostics iterationSnapshot;
            if (!ReadPCMDiagnostics(interface, driverRef, deviceID, &iterationSnapshot)) break;
            if (iterationSnapshot.version != 1) break;

            Boolean hasAfter = interface->HasProperty(driverRef, deviceID, 0, &diagAddress);
            if (!hasAfter) break;

            successCount++;
        }
        Check("100 realistic HasProperty->GetSize->GetData->release->HasProperty cycles all succeed", successCount == 100);
    }

    // §13 investigation — concurrent non-RT reads against the same device (ConcurrentPCMRead
    // below is a plain, non-block static function — a true pthread entry point, not a Clang
    // block cast to a function pointer, which would be an invalid/unsafe ABI mismatch). Two
    // threads hammer Rpcm simultaneously; each must independently decode a self-consistent
    // snapshot (release is per-thread, per-call — no shared state between them since each
    // GetPropertyData call now returns its own freshly created CFData, never a shared mutable
    // object). This is control-plane selftest code, not the realtime callback path, so ordinary
    // threads are fine.
    {
        ConcurrentPCMReadArgs argsA = { interface, driverRef, deviceID, 0 };
        ConcurrentPCMReadArgs argsB = { interface, driverRef, deviceID, 0 };
        pthread_t threadA, threadB;
        int createdA = pthread_create(&threadA, NULL, ConcurrentPCMRead, &argsA);
        int createdB = pthread_create(&threadB, NULL, ConcurrentPCMRead, &argsB);
        Check("concurrent Rpcm reader threads created successfully", createdA == 0 && createdB == 0);
        if (createdA == 0) pthread_join(threadA, NULL);
        if (createdB == 0) pthread_join(threadB, NULL);
        Check("concurrent Rpcm reads: thread A all 200 succeeded (no crash/corruption)", argsA.successCount == 200);
        Check("concurrent Rpcm reads: thread B all 200 succeeded (no crash/corruption)", argsB.successCount == 200);
    }

    // Zero path: reset, then WriteMix/ReadInput all-silence — operation/frame counts must still
    // advance (the callback ran), but non-zero-callback counts and peak must stay exactly zero.
    interface->SetPropertyData(driverRef, deviceID, 0, &clearAddress, 0, NULL, sizeof(triggerValue), &triggerValue);
    float silentBuffer[64 * 2];
    memset(silentBuffer, 0, sizeof(silentBuffer));
    interface->DoIOOperation(driverRef, deviceID, outputStreamID, 0, kAudioServerPlugInIOOperationWriteMix, frameCount, &dummyCycleInfo, silentBuffer, NULL);
    float silentReadBuffer[64 * 2];
    interface->DoIOOperation(driverRef, deviceID, inputStreamID, 0, kAudioServerPlugInIOOperationReadInput, frameCount, &dummyCycleInfo, silentReadBuffer, NULL);

    ok = ReadPCMDiagnostics(interface, driverRef, deviceID, &snapshot);
    Check("PCM diagnostics readable after zero IO", ok);
    if (ok) {
        Check("outputOperationCount == 1 for the zero-PCM cycle (callback ran)", snapshot.outputOperationCount == 1);
        Check("outputNonZeroCallbacks == 0 for all-silence WriteMix", snapshot.outputNonZeroCallbacks == 0);
        Check("outputPeakLinear == 0 for all-silence WriteMix", snapshot.outputPeakLinear == 0.0f);
        Check("inputOperationCount == 1 for the zero-PCM cycle (callback ran)", snapshot.inputOperationCount == 1);
        Check("inputNonZeroCallbacks == 0 for all-silence ReadInput", snapshot.inputNonZeroCallbacks == 0);
        Check("inputPeakLinear == 0 for all-silence ReadInput", snapshot.inputPeakLinear == 0.0f);
        Check("no raw PCM retained — snapshot is aggregate counters/peaks only", sizeof(snapshot) < 128);
    }

    // Leave the device in a clean (reset) state for whatever runs after this.
    interface->SetPropertyData(driverRef, deviceID, 0, &clearAddress, 0, NULL, sizeof(triggerValue), &triggerValue);
}

static void CheckDevice(AudioServerPlugInDriverInterface *interface, AudioServerPlugInDriverRef driverRef,
                         AudioObjectID deviceID, AudioObjectID outputStreamID, AudioObjectID inputStreamID,
                         const char *expectedUID) {
    OSStatus status;
    UInt32 outSize;

    AudioObjectPropertyAddress uidAddress = { kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef uid = NULL;
    status = interface->GetPropertyData(driverRef, deviceID, 0, &uidAddress, 0, NULL, sizeof(uid), &outSize, &uid);
    char label[128];
    snprintf(label, sizeof(label), "GetPropertyData(device %u, DeviceUID)", (unsigned)deviceID);
    Check(label, status == kAudioHardwareNoError);
    PrintCFString("DeviceUID", uid);
    if (uid != NULL) {
        CFStringRef expected = CFStringCreateWithCString(NULL, expectedUID, kCFStringEncodingUTF8);
        Check("DeviceUID matches expected constant", CFEqual(uid, expected));
        CFRelease(expected);
    }

    AudioObjectPropertyAddress hiddenAddress = { kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 hidden = 0;
    status = interface->GetPropertyData(driverRef, deviceID, 0, &hiddenAddress, 0, NULL, sizeof(hidden), &outSize, &hidden);
    Check("GetPropertyData(IsHidden) succeeds", status == kAudioHardwareNoError);
    Check("device starts hidden", hidden == 1);

    AudioObjectPropertyAddress canDefaultAddress = { kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 canDefault = 1;
    status = interface->GetPropertyData(driverRef, deviceID, 0, &canDefaultAddress, 0, NULL, sizeof(canDefault), &outSize, &canDefault);
    Check("GetPropertyData(CanBeDefaultDevice) succeeds", status == kAudioHardwareNoError);
    Check("device cannot be default device while inactive (safety invariant)", canDefault == 0);

    AudioObjectPropertyAddress canDefaultSystemAddress = { kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 canDefaultSystem = 1;
    status = interface->GetPropertyData(driverRef, deviceID, 0, &canDefaultSystemAddress, 0, NULL, sizeof(canDefaultSystem), &outSize, &canDefaultSystem);
    Check("GetPropertyData(CanBeDefaultSystemDevice) succeeds", status == kAudioHardwareNoError);
    Check("device can NEVER be default SYSTEM device, even active (System Output invariant)", canDefaultSystem == 0);

    AudioObjectPropertyAddress outputFormatAddress = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioStreamBasicDescription outputFormat;
    status = interface->GetPropertyData(driverRef, outputStreamID, 0, &outputFormatAddress, 0, NULL, sizeof(outputFormat), &outSize, &outputFormat);
    Check("GetPropertyData(output stream, VirtualFormat) succeeds", status == kAudioHardwareNoError);
    if (status == kAudioHardwareNoError) {
        printf("  output format sampleRate=%.0f channels=%u\n", outputFormat.mSampleRate, (unsigned)outputFormat.mChannelsPerFrame);
        Check("output format is 48kHz/2ch", outputFormat.mSampleRate == 48000 && outputFormat.mChannelsPerFrame == 2);
    }

    AudioObjectPropertyAddress directionAddress = { kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 outputDirection = 99, inputDirection = 99;
    interface->GetPropertyData(driverRef, outputStreamID, 0, &directionAddress, 0, NULL, sizeof(outputDirection), &outSize, &outputDirection);
    interface->GetPropertyData(driverRef, inputStreamID, 0, &directionAddress, 0, NULL, sizeof(inputDirection), &outSize, &inputDirection);
    Check("output stream direction == 0", outputDirection == 0);
    Check("input stream direction == 1", inputDirection == 1);

    // Invalid property handling: an unsupported selector on a real object must return a
    // documented error, never a fabricated success.
    AudioObjectPropertyAddress bogusAddress = { 'bogu', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 bogusOut = 0;
    status = interface->GetPropertyData(driverRef, deviceID, 0, &bogusAddress, 0, NULL, sizeof(bogusOut), &outSize, &bogusOut);
    Check("unknown property returns kAudioHardwareUnknownPropertyError, not success", status == kAudioHardwareUnknownPropertyError);

    // Custom Active control property. Marshaled as CFBoolean (CFPropertyList leaf type) — a raw
    // UInt32 is NOT one of AudioServerPlugIn.h's documented custom-property marshaling types
    // (None/CFString/CFPropertyList) and gets silently rejected by real cross-process property
    // dispatch even though it can appear to work when this driver is exercised in-process
    // (exactly how this bug was found: CHECKPOINT 2 failed against the real installed driver
    // while the old UInt32-based version of this very selftest kept passing).
    AudioObjectPropertyAddress activeAddress = { kJarvisDevicePropertyActive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Boolean hasActive = interface->HasProperty(driverRef, deviceID, 0, &activeAddress);
    Check("HasProperty(Active) == true", hasActive);

    UInt32 activeSize = 0;
    status = interface->GetPropertyDataSize(driverRef, deviceID, 0, &activeAddress, 0, NULL, &activeSize);
    Check("GetPropertyDataSize(Active) succeeds", status == kAudioHardwareNoError && activeSize == sizeof(CFTypeRef));

    CFTypeRef activeValue = kCFBooleanTrue;
    status = interface->SetPropertyData(driverRef, deviceID, 0, &activeAddress, 0, NULL, sizeof(activeValue), &activeValue);
    Check("SetPropertyData(Active=true) succeeds", status == kAudioHardwareNoError);

    CFTypeRef readActive = NULL;
    status = interface->GetPropertyData(driverRef, deviceID, 0, &activeAddress, 0, NULL, sizeof(readActive), &outSize, &readActive);
    Check("GetPropertyData(Active) succeeds after Set", status == kAudioHardwareNoError);
    Check("Active reads back as true after Set", readActive == kCFBooleanTrue);

    UInt32 readHiddenAfterActivate = 1;
    interface->GetPropertyData(driverRef, deviceID, 0, &hiddenAddress, 0, NULL, sizeof(readHiddenAfterActivate), &outSize, &readHiddenAfterActivate);
    Check("IsHidden flips to 0 when Active=true", readHiddenAfterActivate == 0);

    // Real-device fix (Phase 3 CHECKPOINT 1 route-setter investigation): CanBeDefaultDevice must
    // become eligible (1) the moment the device is Active — this is what lets
    // AudioObjectSetPropertyData(kAudioHardwarePropertyDefault{Output,Input}Device) actually take
    // effect against it, not just return noErr without ever converging.
    UInt32 canDefaultAfterActivate = 0;
    status = interface->GetPropertyData(driverRef, deviceID, 0, &canDefaultAddress, 0, NULL, sizeof(canDefaultAfterActivate), &outSize, &canDefaultAfterActivate);
    Check("GetPropertyData(CanBeDefaultDevice) succeeds after Set", status == kAudioHardwareNoError);
    Check("CanBeDefaultDevice flips to 1 when Active=true", canDefaultAfterActivate == 1);

    UInt32 canDefaultSystemAfterActivate = 1;
    interface->GetPropertyData(driverRef, deviceID, 0, &canDefaultSystemAddress, 0, NULL, sizeof(canDefaultSystemAfterActivate), &outSize, &canDefaultSystemAfterActivate);
    Check("CanBeDefaultSystemDevice stays 0 even when Active=true (System Output invariant)", canDefaultSystemAfterActivate == 0);

    Check("PropertiesChanged was called at least once for this activation", gPropertiesChangedCallCount > 0);
    Check("last PropertiesChanged call was for this device", gLastPropertiesChangedObjectID == deviceID);
    Check("last PropertiesChanged call included CanBeDefaultDevice", gLastChangeIncludedCanBeDefaultDevice);
    int propertiesChangedCallCountAfterActivate = gPropertiesChangedCallCount;

    // Scope mismatch: Active is a device-Global-scope-only control; querying it in Input/Output
    // scope must return a clear, documented error, never a fabricated success.
    AudioObjectPropertyAddress activeWrongScope = { kJarvisDevicePropertyActive, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
    CFTypeRef wrongScopeOut = NULL;
    status = interface->GetPropertyData(driverRef, deviceID, 0, &activeWrongScope, 0, NULL, sizeof(wrongScopeOut), &outSize, &wrongScopeOut);
    Check("Active with wrong scope returns kAudioHardwareUnknownPropertyError", status == kAudioHardwareUnknownPropertyError);

    // Reset back to inactive so CheckDevice leaves the device in its expected starting state for
    // any test that runs after it (notably the cross-device independence check in main()).
    CFTypeRef inactiveValue = kCFBooleanFalse;
    interface->SetPropertyData(driverRef, deviceID, 0, &activeAddress, 0, NULL, sizeof(inactiveValue), &inactiveValue);

    UInt32 canDefaultAfterDeactivate = 1;
    interface->GetPropertyData(driverRef, deviceID, 0, &canDefaultAddress, 0, NULL, sizeof(canDefaultAfterDeactivate), &outSize, &canDefaultAfterDeactivate);
    Check("CanBeDefaultDevice flips back to 0 when Active=false", canDefaultAfterDeactivate == 0);
    Check("PropertiesChanged fired again for the deactivation", gPropertiesChangedCallCount > propertiesChangedCallCountAfterActivate);

    // kAudioObjectPropertyCustomPropertyInfoList: the documented discovery mechanism a generic
    // client can use to learn our custom properties' marshaling types without hardcoding them.
    AudioObjectPropertyAddress customListAddress = { kAudioObjectPropertyCustomPropertyInfoList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioServerPlugInCustomPropertyInfo customInfo[4];
    status = interface->GetPropertyData(driverRef, deviceID, 0, &customListAddress, 0, NULL, sizeof(customInfo), &outSize, customInfo);
    Check("GetPropertyData(CustomPropertyInfoList) succeeds", status == kAudioHardwareNoError);
    Check("CustomPropertyInfoList reports 4 entries", outSize == sizeof(customInfo));
    if (status == kAudioHardwareNoError) {
        Check("CustomPropertyInfoList[0] is Active/CFPropertyList",
              customInfo[0].mSelector == kJarvisDevicePropertyActive &&
              customInfo[0].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
        Check("CustomPropertyInfoList[2] is PCMDiagnostics/CFPropertyList",
              customInfo[2].mSelector == kJarvisDevicePropertyPCMDiagnostics &&
              customInfo[2].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
        Check("CustomPropertyInfoList[3] is CaptureRXChunk/CFPropertyList",
              customInfo[3].mSelector == kJarvisDevicePropertyCaptureRXChunk &&
              customInfo[3].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    }

    // Phase 3 CHECKPOINT 2 RX investigation (§13/§32-36) — PCM diagnostics: read-only, starts at
    // zero, and (the "more important than an isolated ring-buffer-only test" case per spec) an
    // exact-operation-semantics integration test: a synthetic client WriteMix with known non-zero
    // Float32 stereo data must be observable, byte-for-byte via the loopback, on the very next
    // ReadInput — proving the real client-write -> DoIOOperation -> loopback -> client-read path,
    // not just the ring buffer in isolation.
    CheckPCMDiagnostics(interface, driverRef, deviceID, outputStreamID, inputStreamID);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <path-to-driver-bundle-executable>\n", argv[0]);
        return 1;
    }

    void *handle = dlopen(argv[1], RTLD_NOW);
    if (handle == NULL) { fprintf(stderr, "FAIL: dlopen failed: %s\n", dlerror()); return 1; }

    FactoryFunc factory = (FactoryFunc)dlsym(handle, "JarvisCallAudioFactory");
    if (factory == NULL) { fprintf(stderr, "FAIL: dlsym(JarvisCallAudioFactory) failed: %s\n", dlerror()); return 1; }

    void *ref = factory(NULL, kAudioServerPlugInTypeUUID);
    Check("factory returns a driver ref", ref != NULL);
    if (ref == NULL) return 1;

    AudioServerPlugInDriverRef driverRef = (AudioServerPlugInDriverRef)ref;
    AudioServerPlugInDriverInterface *interface = *driverRef;

    void *queried = NULL;
    CFUUIDBytes driverInterfaceUUIDBytes = CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID);
    OSStatus status = interface->QueryInterface(driverRef, driverInterfaceUUIDBytes, &queried);
    Check("QueryInterface(kAudioServerPlugInDriverInterfaceUUID)", status == kAudioHardwareNoError && queried != NULL);

    // coreaudiod always calls Initialize() immediately after loading, before any property
    // queries — device UID/name and the loopback buffers are only set up inside it. Real-device
    // fix: the driver now stores inHost and calls back into PropertiesChanged() when Active
    // toggles, so the dummy host below must supply a real PropertiesChanged (matching what real
    // coreaudiod always provides) — an all-zero host would crash the very first activation.
    AudioServerPlugInHostInterface dummyHost = { 0 };
    dummyHost.PropertiesChanged = StubPropertiesChanged;
    (void)shm_unlink(JARVIS_CAPTURE_RX_RING_NAME);
    (void)shm_unlink(JARVIS_SPEAKER_TX_RING_NAME);
    status = interface->Initialize(driverRef, &dummyHost);
    Check("Initialize(driverRef, dummyHost) succeeds", status == kAudioHardwareNoError);

    printf("\n--- PlugIn ---\n");
    UInt32 outSize;
    AudioObjectPropertyAddress deviceListAddress = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectID deviceList[4] = { 0, 0, 0, 0 };
    status = interface->GetPropertyData(driverRef, kAudioObjectPlugInObject, 0, &deviceListAddress, 0, NULL, sizeof(deviceList), &outSize, deviceList);
    Check("GetPropertyData(PlugIn, DeviceList) succeeds", status == kAudioHardwareNoError);
    Check("DeviceList has exactly 4 devices", outSize == sizeof(AudioObjectID) * JARVIS_CALL_AUDIO_DEVICE_COUNT);
    printf("  devices = [%u, %u, %u, %u]\n", (unsigned)deviceList[0], (unsigned)deviceList[1], (unsigned)deviceList[2], (unsigned)deviceList[3]);

    printf("\n--- Jarvis Call Capture ---\n");
    CheckDevice(interface, driverRef, kJarvisCallAudio_Capture_Device, kJarvisCallAudio_Capture_OutputStream, kJarvisCallAudio_Capture_InputStream, "com.jarvis.callbridge.audio.capture");

    printf("\n--- Jarvis Call Inject ---\n");
    CheckDevice(interface, driverRef, kJarvisCallAudio_Inject_Device, kJarvisCallAudio_Inject_OutputStream, kJarvisCallAudio_Inject_InputStream, "com.jarvis.callbridge.audio.inject");

    printf("\n--- Jarvis Speaker ---\n");
    CheckDevice(interface, driverRef, kJarvisCallAudio_Speaker_Device, kJarvisCallAudio_Speaker_OutputStream, kJarvisCallAudio_Speaker_InputStream, "com.jarvis.callbridge.audio.speaker");
    {
        AudioServerPlugInIOCycleInfo dummyCycleInfo = { 0 };
        const UInt32 frameCount = 64;
        float writeBuffer[64 * 2];
        for (UInt32 i = 0; i < frameCount * 2; i++) writeBuffer[i] = 0.25f + (float)i * 0.001f;
        OSStatus writeStatus = interface->DoIOOperation(driverRef, kJarvisCallAudio_Speaker_Device, kJarvisCallAudio_Speaker_OutputStream, 0, kAudioServerPlugInIOOperationWriteMix, frameCount, &dummyCycleInfo, writeBuffer, NULL);
        Check("Speaker WriteMix succeeds", writeStatus == kAudioHardwareNoError);
        JarvisCaptureRXRing speakerRing;
        if (JarvisCaptureRXRingOpenNamed(&speakerRing, JARVIS_SPEAKER_TX_RING_NAME)) {
            float tapped[64 * 2];
            JarvisCaptureRXRingTapLatest(&speakerRing, tapped, frameCount);
            Check("Speaker TX ring matches WriteMix", memcmp(writeBuffer, tapped, sizeof(writeBuffer)) == 0);
            JarvisCaptureRXRingClose(&speakerRing);
        } else {
            Check("Speaker TX shm opens after Initialize+WriteMix", false);
        }
    }

    printf("\n--- Jarvis Call Tap (Capture loopback monitor) ---\n");
    {
        AudioObjectPropertyAddress uidAddress = { kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        CFStringRef uid = NULL;
        status = interface->GetPropertyData(driverRef, kJarvisCallAudio_Tap_Device, 0, &uidAddress, 0, NULL, sizeof(uid), &outSize, &uid);
        Check("GetPropertyData(Tap, DeviceUID)", status == kAudioHardwareNoError);
        if (uid != NULL) {
            Check("Tap UID matches expected constant", CFEqual(uid, CFSTR("com.jarvis.callbridge.audio.tap")));
        }

        AudioObjectPropertyAddress hiddenAddress = { kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectPropertyAddress canDefaultAddress = { kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectPropertyAddress activeAddress = { kJarvisDevicePropertyActive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 hidden = 0, canDefault = 1;
        interface->GetPropertyData(driverRef, kJarvisCallAudio_Tap_Device, 0, &hiddenAddress, 0, NULL, sizeof(hidden), &outSize, &hidden);
        interface->GetPropertyData(driverRef, kJarvisCallAudio_Tap_Device, 0, &canDefaultAddress, 0, NULL, sizeof(canDefault), &outSize, &canDefault);
        Check("Tap starts hidden", hidden == 1);
        Check("Tap cannot be default while inactive", canDefault == 0);

        CFTypeRef trueValue = kCFBooleanTrue;
        CFTypeRef falseValue = kCFBooleanFalse;
        interface->SetPropertyData(driverRef, kJarvisCallAudio_Tap_Device, 0, &activeAddress, 0, NULL, sizeof(trueValue), &trueValue);
        interface->GetPropertyData(driverRef, kJarvisCallAudio_Tap_Device, 0, &hiddenAddress, 0, NULL, sizeof(hidden), &outSize, &hidden);
        interface->GetPropertyData(driverRef, kJarvisCallAudio_Tap_Device, 0, &canDefaultAddress, 0, NULL, sizeof(canDefault), &outSize, &canDefault);
        Check("Tap stays hidden even when Active", hidden == 1);
        Check("Tap can NEVER be default device, even when Active", canDefault == 0);
        interface->SetPropertyData(driverRef, kJarvisCallAudio_Tap_Device, 0, &activeAddress, 0, NULL, sizeof(falseValue), &falseValue);

        /* Tap stays a duplex device. Making it input-only made coreaudiod spin (~150% CPU)
           after install. Unknown object IDs must still be rejected — HasProperty used to
           return true for Class on every id. */
        AudioObjectPropertyAddress ownedAddress = { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 ownedSize = 0;
        status = interface->GetPropertyDataSize(driverRef, kJarvisCallAudio_Tap_Device, 0, &ownedAddress, 0, NULL, &ownedSize);
        Check("Tap OwnedObjects size is two streams", status == kAudioHardwareNoError && ownedSize == sizeof(AudioObjectID) * 2);
        AudioObjectID tapOwned[2] = { 0, 0 };
        status = interface->GetPropertyData(driverRef, kJarvisCallAudio_Tap_Device, 0, &ownedAddress, 0, NULL, sizeof(tapOwned), &outSize, tapOwned);
        Check("Tap owns output then input stream", status == kAudioHardwareNoError && outSize == sizeof(AudioObjectID) * 2 && tapOwned[0] == kJarvisCallAudio_Tap_OutputStream && tapOwned[1] == kJarvisCallAudio_Tap_InputStream);

        Boolean tapWillWrite = false, tapWillRead = false, tapInPlace = false;
        interface->WillDoIOOperation(driverRef, kJarvisCallAudio_Tap_Device, 0, kAudioServerPlugInIOOperationWriteMix, &tapWillWrite, &tapInPlace);
        interface->WillDoIOOperation(driverRef, kJarvisCallAudio_Tap_Device, 0, kAudioServerPlugInIOOperationReadInput, &tapWillRead, &tapInPlace);
        Check("Tap WillDo WriteMix is true", tapWillWrite == true);
        Check("Tap WillDo ReadInput is true", tapWillRead == true);

        AudioObjectPropertyAddress classAddress = { kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Check("HasProperty(Class) on unknown object ID is false",
              interface->HasProperty(driverRef, 99, 0, &classAddress) == false);
        AudioClassID holeClass = 0;
        UInt32 holeSize = 0;
        status = interface->GetPropertyDataSize(driverRef, 99, 0, &classAddress, 0, NULL, &holeSize);
        Check("GetPropertyDataSize(Class) on unknown object ID is BadObject", status == kAudioHardwareBadObjectError);
        status = interface->GetPropertyData(driverRef, 99, 0, &classAddress, 0, NULL, sizeof(holeClass), &outSize, &holeClass);
        Check("GetPropertyData(Class) on unknown object ID is BadObject", status == kAudioHardwareBadObjectError);
        Check("HasProperty(Class) on the real Tap device stays true",
              interface->HasProperty(driverRef, kJarvisCallAudio_Tap_Device, 0, &classAddress) == true);

        const UInt32 frameCount = 64;
        const UInt32 channels = 2;
        float writeBuffer[64 * 2];
        for (UInt32 i = 0; i < frameCount * channels; i++) writeBuffer[i] = 0.5f + (float)i * 0.001f;
        AudioServerPlugInIOCycleInfo dummyCycleInfo;
        memset(&dummyCycleInfo, 0, sizeof(dummyCycleInfo));
        interface->DoIOOperation(driverRef, kJarvisCallAudio_Capture_Device, kJarvisCallAudio_Capture_OutputStream, 0, kAudioServerPlugInIOOperationWriteMix, frameCount, &dummyCycleInfo, writeBuffer, NULL);
        float tapRead[64 * 2];
        memset(tapRead, 0, sizeof(tapRead));
        OSStatus tapReadStatus = interface->DoIOOperation(driverRef, kJarvisCallAudio_Tap_Device, kJarvisCallAudio_Tap_InputStream, 0, kAudioServerPlugInIOOperationReadInput, frameCount, &dummyCycleInfo, tapRead, NULL);
        Check("Tap ReadInput after Capture WriteMix succeeds", tapReadStatus == kAudioHardwareNoError);
        Check("Tap ReadInput returns Capture WriteMix samples (cross-device monitor)", memcmp(writeBuffer, tapRead, sizeof(writeBuffer)) == 0);
        AudioObjectPropertyAddress clearAddress = { kJarvisDevicePropertyClearBuffers, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        CFTypeRef triggerValue = kCFBooleanTrue;
        interface->SetPropertyData(driverRef, kJarvisCallAudio_Capture_Device, 0, &clearAddress, 0, NULL, sizeof(triggerValue), &triggerValue);
    }

    printf("\n--- Cross-device independence (Active state) ---\n");
    {
        AudioObjectPropertyAddress activeAddress = { kJarvisDevicePropertyActive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        CFTypeRef trueValue = kCFBooleanTrue;
        CFTypeRef falseValue = kCFBooleanFalse;

        // Both start inactive (CheckDevice resets each device back to inactive before returning).
        CFTypeRef captureBefore = NULL, injectBefore = NULL;
        interface->GetPropertyData(driverRef, kJarvisCallAudio_Capture_Device, 0, &activeAddress, 0, NULL, sizeof(captureBefore), &outSize, &captureBefore);
        interface->GetPropertyData(driverRef, kJarvisCallAudio_Inject_Device, 0, &activeAddress, 0, NULL, sizeof(injectBefore), &outSize, &injectBefore);
        Check("both devices inactive before independence check", captureBefore == kCFBooleanFalse && injectBefore == kCFBooleanFalse);

        // Activate ONLY Capture; Inject must be unaffected.
        interface->SetPropertyData(driverRef, kJarvisCallAudio_Capture_Device, 0, &activeAddress, 0, NULL, sizeof(trueValue), &trueValue);
        CFTypeRef captureAfter = NULL, injectAfter = NULL;
        interface->GetPropertyData(driverRef, kJarvisCallAudio_Capture_Device, 0, &activeAddress, 0, NULL, sizeof(captureAfter), &outSize, &captureAfter);
        interface->GetPropertyData(driverRef, kJarvisCallAudio_Inject_Device, 0, &activeAddress, 0, NULL, sizeof(injectAfter), &outSize, &injectAfter);
        CFTypeRef tapAfterCapture = NULL;
        interface->GetPropertyData(driverRef, kJarvisCallAudio_Tap_Device, 0, &activeAddress, 0, NULL, sizeof(tapAfterCapture), &outSize, &tapAfterCapture);
        Check("Capture independent state: activating Capture only affects Capture", captureAfter == kCFBooleanTrue && injectAfter == kCFBooleanFalse);
        Check("activating Capture also arms the hidden Tap monitor", tapAfterCapture == kCFBooleanTrue);

        // Clean up, then activate ONLY Inject; Capture must be unaffected.
        interface->SetPropertyData(driverRef, kJarvisCallAudio_Capture_Device, 0, &activeAddress, 0, NULL, sizeof(falseValue), &falseValue);
        interface->SetPropertyData(driverRef, kJarvisCallAudio_Inject_Device, 0, &activeAddress, 0, NULL, sizeof(trueValue), &trueValue);
        interface->GetPropertyData(driverRef, kJarvisCallAudio_Capture_Device, 0, &activeAddress, 0, NULL, sizeof(captureAfter), &outSize, &captureAfter);
        interface->GetPropertyData(driverRef, kJarvisCallAudio_Inject_Device, 0, &activeAddress, 0, NULL, sizeof(injectAfter), &outSize, &injectAfter);
        Check("Inject independent state: activating Inject only affects Inject", captureAfter == kCFBooleanFalse && injectAfter == kCFBooleanTrue);

        interface->SetPropertyData(driverRef, kJarvisCallAudio_Inject_Device, 0, &activeAddress, 0, NULL, sizeof(falseValue), &falseValue);
    }

    printf("\n%d failure(s).\n", gFailures);
    printf("This proves the vtable links and both devices answer property queries correctly —\n");
    printf("it does NOT prove coreaudiod will load it, or that real loopback audio works end to\n");
    printf("end. Use JarvisAudioDriverTool against an installed driver for that.\n");

    return gFailures == 0 ? 0 : 1;
}
