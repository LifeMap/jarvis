#include "PlugInTypes.h"

#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <string.h>

#pragma mark - Static identity constants

static const CFStringRef kJarvis_BundleID = CFSTR("com.jarvis.callbridge.audio");
static const CFStringRef kJarvis_Manufacturer = CFSTR("Jarvis");

static const CFStringRef kCapture_DeviceUID = CFSTR("com.jarvis.callbridge.audio.capture");
static const CFStringRef kCapture_DeviceName = CFSTR("Jarvis Call Capture");
static const CFStringRef kInject_DeviceUID = CFSTR("com.jarvis.callbridge.audio.inject");
static const CFStringRef kInject_DeviceName = CFSTR("Jarvis Call Inject");

static const CFStringRef kTap_DeviceUID = CFSTR("com.jarvis.callbridge.audio.tap");
static const CFStringRef kTap_DeviceName = CFSTR("Jarvis Call Tap");
static const CFStringRef kSpeaker_DeviceUID = CFSTR("com.jarvis.callbridge.audio.speaker");
static const CFStringRef kSpeaker_DeviceName = CFSTR("Jarvis Speaker");

/*
 * Per AudioServerPlugIn.h's own documentation: "kAudioServerPlugInCustomPropertyDataTypeNone /
 * CFString / CFPropertyList ... These are the only types supported for custom properties." A
 * raw UInt32 is NOT one of them — the host's cross-process property marshaling silently rejects
 * it with kAudioHardwareUnknownPropertyError even though HasProperty/GetPropertyData answer
 * correctly in-process (which is why the original UInt32-based selftest passed locally but the
 * real installed driver failed the same call via coreaudiod). Both custom properties are
 * declared here and marshaled as CFBooleanRef (a valid CFPropertyList leaf type) instead.
 */
static const AudioServerPlugInCustomPropertyInfo kCustomPropertyInfo[4] = {
    { kJarvisDevicePropertyActive, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
    { kJarvisDevicePropertyClearBuffers, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
    { kJarvisDevicePropertyPCMDiagnostics, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
    { kJarvisDevicePropertyCaptureRXChunk, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone }
};

#pragma mark - Object/interface plumbing

typedef struct {
    AudioServerPlugInDriverInterface *mInterface;
} JarvisDriverObject;

static OSStatus Driver_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG Driver_AddRef(void *inDriver);
static ULONG Driver_Release(void *inDriver);
static OSStatus Driver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Driver_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus Driver_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus Driver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus Driver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus Driver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus Driver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean Driver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus Driver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus Driver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus Driver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus Driver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus Driver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Driver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus Driver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus Driver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus Driver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus Driver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus Driver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Driver_QueryInterface, Driver_AddRef, Driver_Release,
    Driver_Initialize,
    Driver_CreateDevice, Driver_DestroyDevice,
    Driver_AddDeviceClient, Driver_RemoveDeviceClient,
    Driver_PerformDeviceConfigurationChange, Driver_AbortDeviceConfigurationChange,
    Driver_HasProperty, Driver_IsPropertySettable,
    Driver_GetPropertyDataSize, Driver_GetPropertyData, Driver_SetPropertyData,
    Driver_StartIO, Driver_StopIO, Driver_GetZeroTimeStamp,
    Driver_WillDoIOOperation, Driver_BeginIOOperation, Driver_DoIOOperation, Driver_EndIOOperation
};

static JarvisDriverObject gDriverObject = { &gInterface };
static ULONG gRefCount = 1;

/* Real-device fix (Phase 3 CHECKPOINT 1 route-setter investigation): stored so the
   kJarvisDevicePropertyActive setter can tell the host CanBeDefaultDevice/IsHidden changed —
   without this, coreaudiod's cached view of CanBeDefaultDevice never refreshes, so
   AudioObjectSetPropertyData(kAudioHardwarePropertyDefault{Output,Input}Device) toward one of
   these devices is accepted (returns noErr) but never actually committed. */
static AudioServerPlugInHostRef gPlugInHost = NULL;

AudioServerPlugInDriverRef JarvisCallAudio_GetDriverRef(void) {
    return &gDriverObject.mInterface;
}

#pragma mark - Device state

static Float64 gHostTicksPerFrame = 0;

/* BlackHole/NullAudio-style device clock. Recalculating sample/host time from scratch every
   GetZeroTimeStamp call (anchor + floor(elapsed/period)) drifted the host/sample pair enough
   that HAL ran a software 512-frame IO cycle for extra clients and never called plugin
   ReadInput. Capture-as-default-output still worked because the system output engine drives
   that device. Capture and Tap share one clock because they share one loopback ring. */
typedef struct {
    UInt64 numberTimeStamps;
    UInt64 anchorHostTime;
    Float64 previousTicks;
    UInt64 seed;
} JarvisDeviceClock;

static JarvisDeviceClock gClock_CaptureTap = { .seed = 1 };
static JarvisDeviceClock gClock_Inject = { .seed = 1 };
static JarvisDeviceClock gClock_Speaker = { .seed = 1 };
static pthread_mutex_t gClockMutex = PTHREAD_MUTEX_INITIALIZER;
static JarvisCaptureRXRing gCaptureRXRing;
static JarvisCaptureRXRing gSpeakerTXRing;

static JarvisCallAudioDeviceState gCaptureDevice = {
    .deviceObjectID = kJarvisCallAudio_Capture_Device,
    .outputStreamObjectID = kJarvisCallAudio_Capture_OutputStream,
    .inputStreamObjectID = kJarvisCallAudio_Capture_InputStream,
    .isHidden = true,
    .isActive = false,
    .ioClientCount = 0
};

static JarvisCallAudioDeviceState gInjectDevice = {
    .deviceObjectID = kJarvisCallAudio_Inject_Device,
    .outputStreamObjectID = kJarvisCallAudio_Inject_OutputStream,
    .inputStreamObjectID = kJarvisCallAudio_Inject_InputStream,
    .isHidden = true,
    .isActive = false,
    .ioClientCount = 0
};

static JarvisCallAudioDeviceState gTapDevice = {
    .deviceObjectID = kJarvisCallAudio_Tap_Device,
    .outputStreamObjectID = kJarvisCallAudio_Tap_OutputStream,
    .inputStreamObjectID = kJarvisCallAudio_Tap_InputStream,
    .isHidden = true,
    .isActive = false,
    .ioClientCount = 0
};

static JarvisCallAudioDeviceState gSpeakerDevice = {
    .deviceObjectID = kJarvisCallAudio_Speaker_Device,
    .outputStreamObjectID = kJarvisCallAudio_Speaker_OutputStream,
    .inputStreamObjectID = kJarvisCallAudio_Speaker_InputStream,
    .isHidden = true,
    .isActive = false,
    .ioClientCount = 0
};

static Boolean IsTapDevice(const JarvisCallAudioDeviceState *device) {
    return device == &gTapDevice;
}

static JarvisLoopbackBuffer *LoopbackSourceFor(JarvisCallAudioDeviceState *device) {
    return IsTapDevice(device) ? &gCaptureDevice.loopback : &device->loopback;
}

static JarvisDeviceClock *ClockFor(const JarvisCallAudioDeviceState *device) {
    if (device == &gInjectDevice) return &gClock_Inject;
    if (device == &gSpeakerDevice) return &gClock_Speaker;
    return &gClock_CaptureTap;
}

static void ResetDeviceClock(JarvisDeviceClock *clock) {
    clock->numberTimeStamps = 0;
    clock->anchorHostTime = mach_absolute_time();
    clock->previousTicks = 0.0;
    clock->seed += 1;
    if (clock->seed == 0) clock->seed = 1;
}

static uint32_t SharedCaptureTapClientCount(void) {
    return atomic_load(&gCaptureDevice.ioClientCount) + atomic_load(&gTapDevice.ioClientCount);
}

/* Resolves any AudioObjectID this driver owns (device or one of its two streams) to its owning
   device state. Returns NULL for anything else. */
static JarvisCallAudioDeviceState *ResolveObject(AudioObjectID objectID, Boolean *outIsStream, Boolean *outIsOutputStream) {
    JarvisCallAudioDeviceState *devices[JARVIS_CALL_AUDIO_DEVICE_COUNT] = { &gCaptureDevice, &gInjectDevice, &gTapDevice, &gSpeakerDevice };
    for (int i = 0; i < JARVIS_CALL_AUDIO_DEVICE_COUNT; i++) {
        JarvisCallAudioDeviceState *device = devices[i];
        if (objectID == device->deviceObjectID) {
            if (outIsStream) *outIsStream = false;
            return device;
        }
        if (device->outputStreamObjectID != 0 && objectID == device->outputStreamObjectID) {
            if (outIsStream) *outIsStream = true;
            if (outIsOutputStream) *outIsOutputStream = true;
            return device;
        }
        if (objectID == device->inputStreamObjectID) {
            if (outIsStream) *outIsStream = true;
            if (outIsOutputStream) *outIsOutputStream = false;
            return device;
        }
    }
    return NULL;
}

/* Accepts CFBoolean (expected) or CFNumber (defensive, in case a client marshals a plain number
   instead of a boolean) when interpreting a Set on kJarvisDevicePropertyActive. */
static bool CFTypeRefIsTruthy(CFTypeRef value) {
    if (value == NULL) return false;
    CFTypeID typeID = CFGetTypeID(value);
    if (typeID == CFBooleanGetTypeID()) {
        return CFBooleanGetValue((CFBooleanRef)value);
    }
    if (typeID == CFNumberGetTypeID()) {
        int intValue = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &intValue);
        return intValue != 0;
    }
    return false;
}

/* Control-plane only (never called from Driver_DoIOOperation) — mirrors JarvisLoopbackBufferReset's
   call sites exactly, so a freshly (re)activated device never reports stale PCM diagnostics from a
   previous session. */
static void JarvisPCMDeviceDiagnosticsReset(JarvisCallAudioDeviceState *device) {
    atomic_store(&device->pcmOutputOperationCount, (int64_t)0);
    atomic_store(&device->pcmOutputFrames, (int64_t)0);
    atomic_store(&device->pcmOutputNonZeroCallbacks, (int64_t)0);
    atomic_store(&device->pcmOutputPeakBits, (uint32_t)0);
    atomic_store(&device->pcmInputOperationCount, (int64_t)0);
    atomic_store(&device->pcmInputFrames, (int64_t)0);
    atomic_store(&device->pcmInputNonZeroCallbacks, (int64_t)0);
    atomic_store(&device->pcmInputPeakBits, (uint32_t)0);
}

static void FillStreamFormat(AudioStreamBasicDescription *format) {
    memset(format, 0, sizeof(AudioStreamBasicDescription));
    format->mSampleRate = (Float64)JARVIS_CALL_AUDIO_SAMPLE_RATE;
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format->mBytesPerPacket = sizeof(Float32) * JARVIS_CALL_AUDIO_CHANNEL_COUNT;
    format->mFramesPerPacket = 1;
    format->mBytesPerFrame = sizeof(Float32) * JARVIS_CALL_AUDIO_CHANNEL_COUNT;
    format->mChannelsPerFrame = JARVIS_CALL_AUDIO_CHANNEL_COUNT;
    format->mBitsPerChannel = 32;
}

#pragma mark - IUnknown

static OSStatus Driver_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (outInterface == NULL) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareUnspecifiedError;

    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        gRefCount += 1;
        *outInterface = inDriver;
        CFRelease(requested);
        return kAudioHardwareNoError;
    }
    CFRelease(requested);
    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG Driver_AddRef(void *inDriver) { (void)inDriver; gRefCount += 1; return gRefCount; }
static ULONG Driver_Release(void *inDriver) { (void)inDriver; if (gRefCount > 0) gRefCount -= 1; return gRefCount; }

#pragma mark - Basic Operations

static OSStatus Driver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    (void)inDriver;
    gPlugInHost = inHost;

    gCaptureDevice.deviceUID = kCapture_DeviceUID;
    gCaptureDevice.deviceName = kCapture_DeviceName;
    gInjectDevice.deviceUID = kInject_DeviceUID;
    gInjectDevice.deviceName = kInject_DeviceName;
    gTapDevice.deviceUID = kTap_DeviceUID;
    gTapDevice.deviceName = kTap_DeviceName;
    gSpeakerDevice.deviceUID = kSpeaker_DeviceUID;
    gSpeakerDevice.deviceName = kSpeaker_DeviceName;

    if (!JarvisLoopbackBufferInit(&gCaptureDevice.loopback, JARVIS_CALL_AUDIO_CHANNEL_COUNT, JARVIS_CALL_AUDIO_CAPACITY_FRAMES) ||
        !JarvisLoopbackBufferInit(&gInjectDevice.loopback, JARVIS_CALL_AUDIO_CHANNEL_COUNT, JARVIS_CALL_AUDIO_CAPACITY_FRAMES) ||
        !JarvisLoopbackBufferInit(&gTapDevice.loopback, JARVIS_CALL_AUDIO_CHANNEL_COUNT, JARVIS_CALL_AUDIO_CAPACITY_FRAMES) ||
        !JarvisLoopbackBufferInit(&gSpeakerDevice.loopback, JARVIS_CALL_AUDIO_CHANNEL_COUNT, JARVIS_CALL_AUDIO_CAPACITY_FRAMES)) {
        return kAudioHardwareUnspecifiedError;
    }
    (void)JarvisCaptureRXRingCreate(&gCaptureRXRing);
    (void)JarvisCaptureRXRingCreateNamed(&gSpeakerTXRing, JARVIS_SPEAKER_TX_RING_NAME);

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 hostTicksPerSecond = 1000000000.0 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = hostTicksPerSecond / (Float64)JARVIS_CALL_AUDIO_SAMPLE_RATE;

    return kAudioHardwareNoError;
}

/* Both devices are created statically at Initialize — dynamic CreateDevice/DestroyDevice is not
   supported (see docs/Call_Bridge_v2_Phase_1_Report.md for why the static+hidden lifecycle was
   chosen over dynamic create/destroy). */
static OSStatus Driver_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus Driver_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus Driver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo; return kAudioHardwareNoError;
}
static OSStatus Driver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo; return kAudioHardwareNoError;
}
static OSStatus Driver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo; return kAudioHardwareNoError;
}
static OSStatus Driver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo; return kAudioHardwareNoError;
}

#pragma mark - Property Operations

static Boolean IsKnownObject(AudioObjectID objectID) {
    if (objectID == kAudioObjectPlugInObject) return true;
    return ResolveObject(objectID, NULL, NULL) != NULL;
}

static Boolean Driver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL) return false;
    /* Class/OwnedObjects used to return true for every id. After Tap stopped advertising
       object 9, HAL probed the hole, treated it as another PlugIn, and hung InitializeDevices. */
    if (!IsKnownObject(inObjectID)) return false;

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyOwnedObjects:
            return true;
        default: break;
    }

    if (inObjectID == kAudioObjectPlugInObject) {
        switch (inAddress->mSelector) {
            case kAudioPlugInPropertyBundleID:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
                return true;
            default: return false;
        }
    }

    Boolean isStream = false, isOutputStream = false;
    JarvisCallAudioDeviceState *device = ResolveObject(inObjectID, &isStream, &isOutputStream);
    if (device == NULL) return false;

    if (!isStream) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertyStreams:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioObjectPropertyCustomPropertyInfoList:
                return true;
            case kJarvisDevicePropertyActive:
            case kJarvisDevicePropertyClearBuffers:
            case kJarvisDevicePropertyPCMDiagnostics:
            case kJarvisDevicePropertyCaptureRXChunk:
                // Device-scope custom control — only answer for the scope it was designed for;
                // any other scope is a genuinely unknown property for this selector, not a
                // silent alias (see GetPropertyDataSize/GetPropertyData for the matching check).
                return inAddress->mScope == kAudioObjectPropertyScopeGlobal;
            default: return false;
        }
    } else {
        switch (inAddress->mSelector) {
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                return true;
            default: return false;
        }
    }
}

static OSStatus Driver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;

    Boolean isStream = false;
    JarvisCallAudioDeviceState *device = ResolveObject(inObjectID, &isStream, NULL);
    if (device != NULL && !isStream && inAddress->mScope == kAudioObjectPropertyScopeGlobal &&
        (inAddress->mSelector == kJarvisDevicePropertyActive || inAddress->mSelector == kJarvisDevicePropertyClearBuffers)) {
        *outIsSettable = true;
        return kAudioHardwareNoError;
    }

    *outIsSettable = false;
    return kAudioHardwareNoError;
}

static OSStatus Driver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    if (!IsKnownObject(inObjectID)) return kAudioHardwareBadObjectError;

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            if (inObjectID == kAudioObjectPlugInObject) { *outDataSize = sizeof(AudioObjectID) * JARVIS_CALL_AUDIO_DEVICE_COUNT; return kAudioHardwareNoError; }
            break;
        default: break;
    }

    if (inObjectID == kAudioObjectPlugInObject) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                *outDataSize = sizeof(AudioObjectID) * JARVIS_CALL_AUDIO_DEVICE_COUNT; return kAudioHardwareNoError;
            case kAudioPlugInPropertyBundleID:
                *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToDevice:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    Boolean isStream = false, isOutputStream = false;
    JarvisCallAudioDeviceState *device = ResolveObject(inObjectID, &isStream, &isOutputStream);
    if (device == NULL) return kAudioHardwareBadObjectError;

    if (!isStream) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyOwnedObjects:
                *outDataSize = sizeof(AudioObjectID) * 2; return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
                *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kJarvisDevicePropertyActive:
            case kJarvisDevicePropertyClearBuffers:
            case kJarvisDevicePropertyPCMDiagnostics:
            case kJarvisDevicePropertyCaptureRXChunk:
                if (inAddress->mScope != kAudioObjectPropertyScopeGlobal) return kAudioHardwareUnknownPropertyError;
                *outDataSize = sizeof(CFTypeRef); return kAudioHardwareNoError;
            case kAudioObjectPropertyCustomPropertyInfoList:
                *outDataSize = sizeof(kCustomPropertyInfo); return kAudioHardwareNoError;
            case kAudioDevicePropertyRelatedDevices:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioDevicePropertyStreams:
                if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                    *outDataSize = sizeof(AudioObjectID) * 2;
                } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput || inAddress->mScope == kAudioObjectPropertyScopeInput) {
                    *outDataSize = sizeof(AudioObjectID);
                } else {
                    *outDataSize = 0;
                }
                return kAudioHardwareNoError;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0; return kAudioHardwareNoError;
            case kAudioDevicePropertyNominalSampleRate:
                *outDataSize = sizeof(Float64); return kAudioHardwareNoError;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
            default: return kAudioHardwareUnknownPropertyError;
        }
    } else {
        switch (inAddress->mSelector) {
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *outDataSize = sizeof(AudioStreamBasicDescription); return kAudioHardwareNoError;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                *outDataSize = sizeof(AudioStreamRangedDescription); return kAudioHardwareNoError;
            default: return kAudioHardwareUnknownPropertyError;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Driver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    if (!IsKnownObject(inObjectID)) return kAudioHardwareBadObjectError;

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID *)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        case kAudioObjectPropertyClass: {
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            Boolean isStream = false, isOutputStream = false;
            JarvisCallAudioDeviceState *device = ResolveObject(inObjectID, &isStream, &isOutputStream);
            AudioClassID classID = kAudioPlugInClassID;
            if (device != NULL) classID = isStream ? kAudioStreamClassID : kAudioDeviceClassID;
            *(AudioClassID *)outData = classID; *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyOwner: {
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            Boolean isStream = false;
            JarvisCallAudioDeviceState *device = ResolveObject(inObjectID, &isStream, NULL);
            AudioObjectID owner = kAudioObjectUnknown;
            if (inObjectID == kAudioObjectPlugInObject) owner = kAudioObjectUnknown;
            else if (device != NULL) owner = isStream ? device->deviceObjectID : (AudioObjectID)kAudioObjectPlugInObject;
            *(AudioObjectID *)outData = owner; *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyName: {
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            Boolean isStream = false;
            JarvisCallAudioDeviceState *device = ResolveObject(inObjectID, &isStream, NULL);
            CFStringRef name = kJarvis_Manufacturer;
            if (device != NULL) name = device->deviceName;
            *(CFStringRef *)outData = name; *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = kJarvis_Manufacturer; *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects: {
            if (inObjectID == kAudioObjectPlugInObject) {
                if (inDataSize < sizeof(AudioObjectID) * JARVIS_CALL_AUDIO_DEVICE_COUNT) return kAudioHardwareBadPropertySizeError;
                ((AudioObjectID *)outData)[0] = gCaptureDevice.deviceObjectID;
                ((AudioObjectID *)outData)[1] = gInjectDevice.deviceObjectID;
                ((AudioObjectID *)outData)[2] = gTapDevice.deviceObjectID;
                ((AudioObjectID *)outData)[3] = gSpeakerDevice.deviceObjectID;
                *outDataSize = sizeof(AudioObjectID) * JARVIS_CALL_AUDIO_DEVICE_COUNT; return kAudioHardwareNoError;
            }
            Boolean isStream = false;
            JarvisCallAudioDeviceState *device = ResolveObject(inObjectID, &isStream, NULL);
            if (device != NULL && !isStream) {
                if (inDataSize < sizeof(AudioObjectID) * 2) return kAudioHardwareBadPropertySizeError;
                ((AudioObjectID *)outData)[0] = device->outputStreamObjectID;
                ((AudioObjectID *)outData)[1] = device->inputStreamObjectID;
                *outDataSize = sizeof(AudioObjectID) * 2; return kAudioHardwareNoError;
            }
            *outDataSize = 0; return kAudioHardwareNoError;
        }
        default: break;
    }

    if (inObjectID == kAudioObjectPlugInObject) {
        switch (inAddress->mSelector) {
            case kAudioPlugInPropertyBundleID:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = kJarvis_BundleID; *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioPlugInPropertyDeviceList:
                if (inDataSize < sizeof(AudioObjectID) * JARVIS_CALL_AUDIO_DEVICE_COUNT) return kAudioHardwareBadPropertySizeError;
                ((AudioObjectID *)outData)[0] = gCaptureDevice.deviceObjectID;
                ((AudioObjectID *)outData)[1] = gInjectDevice.deviceObjectID;
                ((AudioObjectID *)outData)[2] = gTapDevice.deviceObjectID;
                ((AudioObjectID *)outData)[3] = gSpeakerDevice.deviceObjectID;
                *outDataSize = sizeof(AudioObjectID) * JARVIS_CALL_AUDIO_DEVICE_COUNT; return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                if (inQualifierDataSize < sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareIllegalOperationError;
                CFStringRef uid = *(const CFStringRef *)inQualifierData;
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                AudioObjectID found = kAudioObjectUnknown;
                if (uid != NULL) {
                    if (CFEqual(uid, gCaptureDevice.deviceUID)) found = gCaptureDevice.deviceObjectID;
                    else if (CFEqual(uid, gInjectDevice.deviceUID)) found = gInjectDevice.deviceObjectID;
                    else if (CFEqual(uid, gTapDevice.deviceUID)) found = gTapDevice.deviceObjectID;
                    else if (CFEqual(uid, gSpeakerDevice.deviceUID)) found = gSpeakerDevice.deviceObjectID;
                }
                *(AudioObjectID *)outData = found; *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    Boolean isStream = false, isOutputStream = false;
    JarvisCallAudioDeviceState *device = ResolveObject(inObjectID, &isStream, &isOutputStream);
    if (device == NULL) return kAudioHardwareBadObjectError;

    if (!isStream) {
        switch (inAddress->mSelector) {
            case kAudioDevicePropertyDeviceUID:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = device->deviceUID; *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioDevicePropertyModelUID:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = device->deviceUID; *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioDevicePropertyTransportType:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyClockDomain:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsAlive:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsRunning:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = (atomic_load(&device->ioClientCount) > 0) ? 1 : 0;
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                /* Always false, every scope — Default *System* Output is never something Jarvis
                   sets (CallAudioRouteControlling has no setter for it at all, PRD §11's "System
                   Output must never change" invariant), so this device must never be eligible for
                   it regardless of Active state. */
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                /* Real-device fix: tied to isActive, mirroring IsHidden. While inactive (the
                   default state whenever Jarvis isn't actively routing a call), this is false —
                   the device can never be picked as Default Input/Output, by the user or by
                   macOS, matching Phase 1's original safety intent (PRD §10). Only while
                   Jarvis has explicitly activated the device (via kJarvisDevicePropertyActive,
                   immediately before its own CallAudioSessionController route-takeover attempt)
                   does this become eligible — which is exactly the narrow window in which the
                   default-route setter in SystemCallAudioRouteController needs it to be true for
                   AudioObjectSetPropertyData(kAudioHardwarePropertyDefault{Output,Input}Device)
                   to actually take effect, not just return noErr without ever converging.
                   Tap is never eligible — it exists only so Bridge can open a private input. */
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = (!IsTapDevice(device) && atomic_load(&device->isActive)) ? 1 : 0;
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = JARVIS_CALL_AUDIO_ZERO_TIMESTAMP_PERIOD; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyIsHidden:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                /* Tap stays hidden even while Active so it never appears in Sound settings. */
                *(UInt32 *)outData = (IsTapDevice(device) || atomic_load(&device->isHidden)) ? 1 : 0;
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kJarvisDevicePropertyActive:
                if (inAddress->mScope != kAudioObjectPropertyScopeGlobal) return kAudioHardwareUnknownPropertyError;
                if (inDataSize < sizeof(CFTypeRef)) return kAudioHardwareBadPropertySizeError;
                *(CFTypeRef *)outData = atomic_load(&device->isActive) ? kCFBooleanTrue : kCFBooleanFalse;
                *outDataSize = sizeof(CFTypeRef); return kAudioHardwareNoError;
            case kJarvisDevicePropertyClearBuffers:
                if (inAddress->mScope != kAudioObjectPropertyScopeGlobal) return kAudioHardwareUnknownPropertyError;
                if (inDataSize < sizeof(CFTypeRef)) return kAudioHardwareBadPropertySizeError;
                *(CFTypeRef *)outData = kCFBooleanFalse; // write-only trigger; nothing meaningful to read back
                *outDataSize = sizeof(CFTypeRef); return kAudioHardwareNoError;
            case kJarvisDevicePropertyPCMDiagnostics: {
                if (inAddress->mScope != kAudioObjectPropertyScopeGlobal) return kAudioHardwareUnknownPropertyError;
                if (inDataSize < sizeof(CFTypeRef)) return kAudioHardwareBadPropertySizeError;

                JarvisPCMDeviceDiagnostics snapshot;
                snapshot.version = 1;
                snapshot.ioClientCount = atomic_load(&device->ioClientCount);
                snapshot.outputOperationCount = atomic_load(&device->pcmOutputOperationCount);
                snapshot.outputFrames = atomic_load(&device->pcmOutputFrames);
                snapshot.outputNonZeroCallbacks = atomic_load(&device->pcmOutputNonZeroCallbacks);
                {
                    uint32_t bits = atomic_load(&device->pcmOutputPeakBits);
                    memcpy(&snapshot.outputPeakLinear, &bits, sizeof(bits));
                }
                JarvisLoopbackBufferGetCounters(LoopbackSourceFor(device), &snapshot.loopbackWriteFrames, &snapshot.loopbackReadFrames, &snapshot.loopbackUnderrunCount, &snapshot.loopbackOverrunFrameCount);
                snapshot.inputOperationCount = atomic_load(&device->pcmInputOperationCount);
                snapshot.inputFrames = atomic_load(&device->pcmInputFrames);
                snapshot.inputNonZeroCallbacks = atomic_load(&device->pcmInputNonZeroCallbacks);
                {
                    uint32_t bits = atomic_load(&device->pcmInputPeakBits);
                    memcpy(&snapshot.inputPeakLinear, &bits, sizeof(bits));
                }

                // Real-device CF ownership investigation fix: a single persistent, driver-owned
                // CFMutableDataRef returned (without an extra CFRetain) on every call worked
                // fine in-process (this vtable invoked directly, as every existing selftest
                // does) but failed against real coreaudiod — the very first Rpcm read succeeded,
                // then every subsequent read failed (first with an undocumented OSStatus, then
                // consistently with kAudioHardwareUnknownPropertyError). AudioServerPlugIn.h
                // documents CFPropertyList custom-property values in only one place with
                // explicit ownership language — CopyFromStorage's "the caller is responsible for
                // releasing the returned CFObject" (a "Copy"-style +1-owned contract) — and every
                // OTHER CFTypeRef this driver has ever returned (kJarvisDevicePropertyActive's
                // kCFBooleanTrue/False, every CFSTR literal DeviceUID/DeviceName) is a compiler
                // constant CF object, which the CF runtime treats as immortal and immune to being
                // freed by an over-release. Rpcm's persistent CFMutableDataRef was the first
                // non-immortal, heap-allocated CFTypeRef this driver ever handed out through
                // GetPropertyData — exactly the class of object where a "host releases what the
                // driver returns" contract, if real, would first become observable as a
                // use-after-free instead of a harmless no-op. The fix: return a brand-new,
                // immutable, single-owner CFDataRef built fresh on every call instead of a
                // shared, mutated-in-place object the driver keeps a lingering reference to —
                // correct regardless of which ownership convention the host actually implements
                // (if the host releases it, that's exactly what a freshly created +1 object is
                // for; if the host never releases it, this ~104-byte allocation is bounded,
                // control-plane-only, and never reachable from Driver_DoIOOperation/any realtime
                // callback — see §16 below). This also removes the shared-mutable-scratch
                // concurrent-read race a persistent CFMutableDataRef exposed (§11).
                CFDataRef data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&snapshot, (CFIndex)sizeof(snapshot));
                if (data == NULL) return kAudioHardwareUnspecifiedError;
                *(CFTypeRef *)outData = data;
                *outDataSize = sizeof(CFTypeRef);
                return kAudioHardwareNoError;
            }
            case kJarvisDevicePropertyCaptureRXChunk: {
                if (inAddress->mScope != kAudioObjectPropertyScopeGlobal) return kAudioHardwareUnknownPropertyError;
                if (inDataSize < sizeof(CFTypeRef)) return kAudioHardwareBadPropertySizeError;

                JarvisCaptureRXFallbackChunk chunk;
                memset(&chunk, 0, sizeof(chunk));
                chunk.version = 1;
                chunk.channelCount = JARVIS_CALL_AUDIO_CHANNEL_COUNT;
                if (device == &gCaptureDevice) {
                    uint32_t slot = atomic_load_explicit(&device->rxFallbackPublishedSlot, memory_order_acquire);
                    slot &= 1u;
                    uint32_t frameCount = device->rxFallbackFrameCount[slot];
                    if (frameCount > JARVIS_CAPTURE_RX_FALLBACK_MAX_FRAMES) {
                        frameCount = JARVIS_CAPTURE_RX_FALLBACK_MAX_FRAMES;
                    }
                    chunk.frameCount = frameCount;
                    if (frameCount > 0) {
                        memcpy(chunk.samples, device->rxFallbackSamples[slot], (size_t)frameCount * JARVIS_CALL_AUDIO_CHANNEL_COUNT * sizeof(float));
                    }
                }
                CFDataRef data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&chunk, (CFIndex)sizeof(chunk));
                if (data == NULL) return kAudioHardwareUnspecifiedError;
                *(CFTypeRef *)outData = data;
                *outDataSize = sizeof(CFTypeRef);
                return kAudioHardwareNoError;
            }
            case kAudioObjectPropertyCustomPropertyInfoList:
                if (inDataSize < sizeof(kCustomPropertyInfo)) return kAudioHardwareBadPropertySizeError;
                memcpy(outData, kCustomPropertyInfo, sizeof(kCustomPropertyInfo));
                *outDataSize = sizeof(kCustomPropertyInfo); return kAudioHardwareNoError;
            case kAudioDevicePropertyRelatedDevices:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                ((AudioObjectID *)outData)[0] = device->deviceObjectID; *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioDevicePropertyStreams:
                if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                    if (inDataSize < sizeof(AudioObjectID) * 2) return kAudioHardwareBadPropertySizeError;
                    ((AudioObjectID *)outData)[0] = device->outputStreamObjectID;
                    ((AudioObjectID *)outData)[1] = device->inputStreamObjectID;
                    *outDataSize = sizeof(AudioObjectID) * 2;
                } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    ((AudioObjectID *)outData)[0] = device->outputStreamObjectID;
                    *outDataSize = sizeof(AudioObjectID);
                } else if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    ((AudioObjectID *)outData)[0] = device->inputStreamObjectID;
                    *outDataSize = sizeof(AudioObjectID);
                } else {
                    *outDataSize = 0;
                }
                return kAudioHardwareNoError;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0; return kAudioHardwareNoError;
            case kAudioDevicePropertyNominalSampleRate:
                if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                *(Float64 *)outData = (Float64)JARVIS_CALL_AUDIO_SAMPLE_RATE; *outDataSize = sizeof(Float64); return kAudioHardwareNoError;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
                ((AudioValueRange *)outData)[0].mMinimum = (Float64)JARVIS_CALL_AUDIO_SAMPLE_RATE;
                ((AudioValueRange *)outData)[0].mMaximum = (Float64)JARVIS_CALL_AUDIO_SAMPLE_RATE;
                *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
            default: return kAudioHardwareUnknownPropertyError;
        }
    } else {
        switch (inAddress->mSelector) {
            case kAudioStreamPropertyIsActive:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyDirection:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = isOutputStream ? 0u : 1u; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyTerminalType:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = kAudioStreamTerminalTypeLine; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyStartingChannel:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                FillStreamFormat((AudioStreamBasicDescription *)outData);
                *outDataSize = sizeof(AudioStreamBasicDescription); return kAudioHardwareNoError;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                if (inDataSize < sizeof(AudioStreamRangedDescription)) return kAudioHardwareBadPropertySizeError;
                AudioStreamRangedDescription *ranged = (AudioStreamRangedDescription *)outData;
                FillStreamFormat(&ranged->mFormat);
                ranged->mSampleRateRange.mMinimum = (Float64)JARVIS_CALL_AUDIO_SAMPLE_RATE;
                ranged->mSampleRateRange.mMaximum = (Float64)JARVIS_CALL_AUDIO_SAMPLE_RATE;
                *outDataSize = sizeof(AudioStreamRangedDescription); return kAudioHardwareNoError;
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }
}

static OSStatus Driver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL) return kAudioHardwareIllegalOperationError;

    Boolean isStream = false;
    JarvisCallAudioDeviceState *device = ResolveObject(inObjectID, &isStream, NULL);
    if (device == NULL || isStream) return kAudioHardwareUnsupportedOperationError;

    switch (inAddress->mSelector) {
        case kJarvisDevicePropertyActive: {
            if (inAddress->mScope != kAudioObjectPropertyScopeGlobal) return kAudioHardwareUnknownPropertyError;
            if (inDataSize < sizeof(CFTypeRef) || inData == NULL) return kAudioHardwareBadPropertySizeError;
            bool active = CFTypeRefIsTruthy(*(const CFTypeRef *)inData);
            atomic_store(&device->isActive, active);
            if (!IsTapDevice(device)) {
                atomic_store(&device->isHidden, !active);
            }
            JarvisLoopbackBufferReset(&device->loopback);
            JarvisPCMDeviceDiagnosticsReset(device);
            /* Capture Active also arms the hidden tap so Bridge can open it without a second
               user-visible default-device. Inject stays independent. */
            if (device == &gCaptureDevice) {
                atomic_store(&gTapDevice.isActive, active);
                JarvisLoopbackBufferReset(&gTapDevice.loopback);
                JarvisPCMDeviceDiagnosticsReset(&gTapDevice);
            }
            /* Real-device fix: IsHidden and CanBeDefaultDevice both just changed as a side effect
               of Active — neither affects IO or device structure (they're simple capability/
               visibility flags, not stream/format changes), so per AudioServerPlugIn.h's own
               contract this is exactly the class of change PropertiesChanged() (not
               RequestDeviceConfigurationChange()) is for. Without this, coreaudiod can keep using
               a stale (pre-activation) CanBeDefaultDevice=false it cached earlier, silently
               ignoring the very next SetDefaultOutputDevice/SetDefaultInputDevice request even
               though that call itself still returns noErr. */
            if (gPlugInHost != NULL) {
                AudioObjectPropertyAddress changed[2] = {
                    { kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                    { kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
                };
                gPlugInHost->PropertiesChanged(gPlugInHost, device->deviceObjectID, 2, changed);
            }
            return kAudioHardwareNoError;
        }
        case kJarvisDevicePropertyClearBuffers:
            if (inAddress->mScope != kAudioObjectPropertyScopeGlobal) return kAudioHardwareUnknownPropertyError;
            // Value is ignored on purpose — any Set (even CFBooleanFalse) triggers a reset.
            JarvisLoopbackBufferReset(&device->loopback);
            JarvisPCMDeviceDiagnosticsReset(device);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnsupportedOperationError;
    }
}

#pragma mark - IO Operations

static OSStatus Driver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inClientID;
    Boolean isStream = false;
    JarvisCallAudioDeviceState *device = ResolveObject(inDeviceObjectID, &isStream, NULL);
    if (device == NULL) return kAudioHardwareBadDeviceError;

    uint32_t previous = atomic_fetch_add(&device->ioClientCount, 1);
    pthread_mutex_lock(&gClockMutex);
    if (device == &gInjectDevice) {
        if (previous == 0) ResetDeviceClock(&gClock_Inject);
    } else if (device == &gSpeakerDevice) {
        if (previous == 0) ResetDeviceClock(&gClock_Speaker);
    } else if (previous == 0 && SharedCaptureTapClientCount() == 1) {
        /* First client across Capture+Tap — start the shared timeline. */
        ResetDeviceClock(&gClock_CaptureTap);
    }
    pthread_mutex_unlock(&gClockMutex);
    return kAudioHardwareNoError;
}

static OSStatus Driver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inClientID;
    Boolean isStream = false;
    JarvisCallAudioDeviceState *device = ResolveObject(inDeviceObjectID, &isStream, NULL);
    if (device == NULL) return kAudioHardwareBadDeviceError;

    uint32_t current = atomic_load(&device->ioClientCount);
    if (current > 0) atomic_fetch_sub(&device->ioClientCount, 1);
    return kAudioHardwareNoError;
}

static OSStatus Driver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inDriver; (void)inClientID;
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) return kAudioHardwareIllegalOperationError;
    Boolean isStream = false;
    JarvisCallAudioDeviceState *device = ResolveObject(inDeviceObjectID, &isStream, NULL);
    if (device == NULL) return kAudioHardwareBadDeviceError;

    JarvisDeviceClock *clock = ClockFor(device);
    pthread_mutex_lock(&gClockMutex);
    if (clock->anchorHostTime == 0) {
        ResetDeviceClock(clock);
    }
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)JARVIS_CALL_AUDIO_ZERO_TIMESTAMP_PERIOD;
    Float64 nextTickOffset = clock->previousTicks + ticksPerPeriod;
    UInt64 nextHostTime = clock->anchorHostTime + (UInt64)nextTickOffset;
    if (nextHostTime <= now) {
        clock->numberTimeStamps += 1;
        clock->previousTicks = nextTickOffset;
    }
    *outSampleTime = (Float64)clock->numberTimeStamps * (Float64)JARVIS_CALL_AUDIO_ZERO_TIMESTAMP_PERIOD;
    *outHostTime = clock->anchorHostTime + (UInt64)clock->previousTicks;
    *outSeed = clock->seed;
    pthread_mutex_unlock(&gClockMutex);
    return kAudioHardwareNoError;
}

static OSStatus Driver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    Boolean willDo = (inOperationID == kAudioServerPlugInIOOperationReadInput || inOperationID == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo != NULL) *outWillDo = willDo;
    /* AudioServerPlugIn.h: ReadInput/WriteMix "always happens in-place in the main buffer".
       Setting this false made HAL expect results in ioSecondaryBuffer while we only wrote
       ioMainBuffer — that cannot deliver samples to a client IOProc. Always in-place. */
    if (outWillDoInPlace != NULL) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus Driver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

/* Real-time-safe: callback-local (stack) accumulation only, a handful of relaxed atomic stores at
   the end — no logging/allocation/locks. Mirrors the exact pattern already used by
   JarvisPCMCaptureIOProc's RX peak/mean-square computation (Sources/JarvisPCMRealtime). Peak is
   the most recent callback's value, not a running max — same convention as that file. */
static Boolean JarvisPCMComputePeakAndNonZero(const float *frames, uint32_t frameCount, uint32_t channels, float *outPeak) {
    float peak = 0.0f;
    Boolean nonZero = false;
    uint32_t sampleCount = frameCount * channels;
    for (uint32_t s = 0; s < sampleCount; s++) {
        float sample = frames[s];
        if (sample != 0.0f) nonZero = true;
        float magnitude = fabsf(sample);
        if (magnitude > peak) peak = magnitude;
    }
    *outPeak = peak;
    return nonZero;
}

/* Real-time IO thread. Never blocks/allocates/logs — JarvisLoopbackBuffer's Read/Write are both
   lock-free and return immediately. WriteMix is the Output stream's "hardware sink" (we capture
   what was written instead of handing it to real hardware); ReadInput is the Input stream's
   "hardware source" (we hand back whatever this same device's Output side produced). This is the
   entire Output->Input loopback — no other code path connects them.
   Phase 3 CHECKPOINT 2 RX investigation (§10) — each branch also publishes RT-safe aggregate
   telemetry (operation count, frame count, non-zero-callback count, peak) for the read-only PCM
   diagnostics property, so a real-device retest can prove which pipeline stage first sees zero
   PCM instead of guessing. */
static void PublishCaptureRXFallback(JarvisCallAudioDeviceState *device, const float *frames, UInt32 frameCount) {
    if (device == NULL || frames == NULL || frameCount == 0) return;
    uint32_t current = atomic_load_explicit(&device->rxFallbackPublishedSlot, memory_order_relaxed);
    uint32_t slot = 1u - (current & 1u);
    uint32_t n = frameCount;
    const float *src = frames;
    if (n > JARVIS_CAPTURE_RX_FALLBACK_MAX_FRAMES) {
        src = frames + (size_t)(n - JARVIS_CAPTURE_RX_FALLBACK_MAX_FRAMES) * JARVIS_CALL_AUDIO_CHANNEL_COUNT;
        n = JARVIS_CAPTURE_RX_FALLBACK_MAX_FRAMES;
    }
    memcpy(device->rxFallbackSamples[slot], src, (size_t)n * JARVIS_CALL_AUDIO_CHANNEL_COUNT * sizeof(float));
    device->rxFallbackFrameCount[slot] = n;
    atomic_store_explicit(&device->rxFallbackPublishedSlot, slot, memory_order_release);
}

static OSStatus Driver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inDriver; (void)inClientID; (void)inIOCycleInfo; (void)ioSecondaryBuffer; (void)inStreamObjectID;

    // inDeviceObjectID always identifies the owning device (never a stream ID) per
    // AudioServerPlugIn.h's DoIOOperation contract; inOperationID alone tells us direction.
    JarvisCallAudioDeviceState *device = ResolveObject(inDeviceObjectID, NULL, NULL);
    if (device == NULL || ioMainBuffer == NULL) return kAudioHardwareNoError;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        float peak = 0.0f;
        Boolean nonZero = JarvisPCMComputePeakAndNonZero((const float *)ioMainBuffer, inIOBufferFrameSize, JARVIS_CALL_AUDIO_CHANNEL_COUNT, &peak);
        atomic_fetch_add_explicit(&device->pcmOutputOperationCount, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&device->pcmOutputFrames, (int64_t)inIOBufferFrameSize, memory_order_relaxed);
        if (nonZero) atomic_fetch_add_explicit(&device->pcmOutputNonZeroCallbacks, 1, memory_order_relaxed);
        uint32_t peakBits;
        memcpy(&peakBits, &peak, sizeof(peakBits));
        atomic_store_explicit(&device->pcmOutputPeakBits, peakBits, memory_order_relaxed);

        /* Tap is a monitor, not a second sink. Phone.app writes Capture; writing Tap's unused
           output must not mix into Capture's loopback. */
        if (!IsTapDevice(device)) {
            JarvisLoopbackBufferWrite(&device->loopback, (const float *)ioMainBuffer, inIOBufferFrameSize);
            if (device == &gCaptureDevice) {
                JarvisCaptureRXRingWrite(&gCaptureRXRing, (const float *)ioMainBuffer, inIOBufferFrameSize);
                PublishCaptureRXFallback(device, (const float *)ioMainBuffer, inIOBufferFrameSize);
            } else if (device == &gSpeakerDevice) {
                JarvisCaptureRXRingWrite(&gSpeakerTXRing, (const float *)ioMainBuffer, inIOBufferFrameSize);
            }
        }
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        /* Tap, do not drain. Capture is default output: the system client's unused duplex
           ReadInput already consumes one exclusive reader. A drain here would leave Bridge's
           later ReadInput with silence even when WriteMix just delivered real call audio.
           The Tap device reads the same Capture ring so its own HAL client gets a real ReadInput. */
        JarvisLoopbackBufferTapLatest(LoopbackSourceFor(device), (float *)ioMainBuffer, inIOBufferFrameSize);
        /* WillDoIOOperation() says in-place, so the host should use ioMainBuffer only. If a host
           still passes a distinct secondary (AudioServerPlugIn.h: non-in-place results "must end
           up in this buffer"), copy so the client IOProc cannot be left with an untouched buffer. */
        if (ioSecondaryBuffer != NULL && ioSecondaryBuffer != ioMainBuffer) {
            memcpy(ioSecondaryBuffer, ioMainBuffer, (size_t)inIOBufferFrameSize * JARVIS_CALL_AUDIO_CHANNEL_COUNT * sizeof(float));
        }

        float peak = 0.0f;
        Boolean nonZero = JarvisPCMComputePeakAndNonZero((const float *)ioMainBuffer, inIOBufferFrameSize, JARVIS_CALL_AUDIO_CHANNEL_COUNT, &peak);
        atomic_fetch_add_explicit(&device->pcmInputOperationCount, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&device->pcmInputFrames, (int64_t)inIOBufferFrameSize, memory_order_relaxed);
        if (nonZero) atomic_fetch_add_explicit(&device->pcmInputNonZeroCallbacks, 1, memory_order_relaxed);
        uint32_t peakBits;
        memcpy(&peakBits, &peak, sizeof(peakBits));
        atomic_store_explicit(&device->pcmInputPeakBits, peakBits, memory_order_relaxed);
    }
    return kAudioHardwareNoError;
}

static OSStatus Driver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}
