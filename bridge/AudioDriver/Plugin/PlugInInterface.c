#include "PlugInTypes.h"

#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <math.h>
#include <string.h>

#pragma mark - Static identity constants

static const CFStringRef kJarvis_BundleID = CFSTR("com.jarvis.callbridge.audio");
static const CFStringRef kJarvis_Manufacturer = CFSTR("Jarvis");

static const CFStringRef kCapture_DeviceUID = CFSTR("com.jarvis.callbridge.audio.capture");
static const CFStringRef kCapture_DeviceName = CFSTR("Jarvis Call Capture");
static const CFStringRef kInject_DeviceUID = CFSTR("com.jarvis.callbridge.audio.inject");
static const CFStringRef kInject_DeviceName = CFSTR("Jarvis Call Inject");

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

AudioServerPlugInDriverRef JarvisCallAudio_GetDriverRef(void) {
    return &gDriverObject.mInterface;
}

#pragma mark - Device state

static UInt64 gZeroTimeAnchor_Capture = 0;
static UInt64 gZeroTimeAnchor_Inject = 0;
static Float64 gHostTicksPerFrame = 0;

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

static UInt64 *ZeroTimeAnchorFor(JarvisCallAudioDeviceState *device) {
    return (device == &gCaptureDevice) ? &gZeroTimeAnchor_Capture : &gZeroTimeAnchor_Inject;
}

/* Resolves any AudioObjectID this driver owns (device or one of its two streams) to its owning
   device state. Returns NULL for anything else. */
static JarvisCallAudioDeviceState *ResolveObject(AudioObjectID objectID, Boolean *outIsStream, Boolean *outIsOutputStream) {
    JarvisCallAudioDeviceState *devices[2] = { &gCaptureDevice, &gInjectDevice };
    for (int i = 0; i < 2; i++) {
        JarvisCallAudioDeviceState *device = devices[i];
        if (objectID == device->deviceObjectID) {
            if (outIsStream) *outIsStream = false;
            return device;
        }
        if (objectID == device->outputStreamObjectID) {
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
    (void)inDriver; (void)inHost;

    gCaptureDevice.deviceUID = kCapture_DeviceUID;
    gCaptureDevice.deviceName = kCapture_DeviceName;
    gInjectDevice.deviceUID = kInject_DeviceUID;
    gInjectDevice.deviceName = kInject_DeviceName;

    if (!JarvisLoopbackBufferInit(&gCaptureDevice.loopback, JARVIS_CALL_AUDIO_CHANNEL_COUNT, JARVIS_CALL_AUDIO_CAPACITY_FRAMES) ||
        !JarvisLoopbackBufferInit(&gInjectDevice.loopback, JARVIS_CALL_AUDIO_CHANNEL_COUNT, JARVIS_CALL_AUDIO_CAPACITY_FRAMES)) {
        return kAudioHardwareUnspecifiedError;
    }

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

static Boolean IsInputOrGlobalScope(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput;
}
static Boolean IsOutputOrGlobalScope(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput;
}

static Boolean Driver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL) return false;

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
            case kJarvisDevicePropertyActive:
            case kJarvisDevicePropertyClearBuffers:
                return true;
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
    if (device != NULL && !isStream &&
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

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            if (inObjectID == kAudioObjectPlugInObject) { *outDataSize = sizeof(AudioObjectID) * 2; return kAudioHardwareNoError; }
            break;
        default: break;
    }

    if (inObjectID == kAudioObjectPlugInObject) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                *outDataSize = sizeof(AudioObjectID) * 2; return kAudioHardwareNoError;
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
            case kJarvisDevicePropertyActive:
            case kJarvisDevicePropertyClearBuffers:
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyRelatedDevices:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioDevicePropertyStreams:
                if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) { *outDataSize = sizeof(AudioObjectID) * 2; }
                else if (IsInputOrGlobalScope(inAddress->mScope) || IsOutputOrGlobalScope(inAddress->mScope)) { *outDataSize = sizeof(AudioObjectID); }
                else { *outDataSize = 0; }
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
                if (inDataSize < sizeof(AudioObjectID) * 2) return kAudioHardwareBadPropertySizeError;
                ((AudioObjectID *)outData)[0] = gCaptureDevice.deviceObjectID;
                ((AudioObjectID *)outData)[1] = gInjectDevice.deviceObjectID;
                *outDataSize = sizeof(AudioObjectID) * 2; return kAudioHardwareNoError;
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
                if (inDataSize < sizeof(AudioObjectID) * 2) return kAudioHardwareBadPropertySizeError;
                ((AudioObjectID *)outData)[0] = gCaptureDevice.deviceObjectID;
                ((AudioObjectID *)outData)[1] = gInjectDevice.deviceObjectID;
                *outDataSize = sizeof(AudioObjectID) * 2; return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                if (inQualifierDataSize < sizeof(CFStringRef) || inQualifierData == NULL) return kAudioHardwareIllegalOperationError;
                CFStringRef uid = *(const CFStringRef *)inQualifierData;
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                AudioObjectID found = kAudioObjectUnknown;
                if (uid != NULL) {
                    if (CFEqual(uid, gCaptureDevice.deviceUID)) found = gCaptureDevice.deviceObjectID;
                    else if (CFEqual(uid, gInjectDevice.deviceUID)) found = gInjectDevice.deviceObjectID;
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
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                /* Always false, every scope — the primary safety mechanism preventing this
                   driver from ever becoming the system default input/output (PRD §10). */
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = JARVIS_CALL_AUDIO_ZERO_TIMESTAMP_PERIOD; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyIsHidden:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = atomic_load(&device->isHidden) ? 1 : 0; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kJarvisDevicePropertyActive:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = atomic_load(&device->isActive) ? 1 : 0; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kJarvisDevicePropertyClearBuffers:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyRelatedDevices:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                ((AudioObjectID *)outData)[0] = device->deviceObjectID; *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioDevicePropertyStreams:
                if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                    if (inDataSize < sizeof(AudioObjectID) * 2) return kAudioHardwareBadPropertySizeError;
                    ((AudioObjectID *)outData)[0] = device->outputStreamObjectID;
                    ((AudioObjectID *)outData)[1] = device->inputStreamObjectID;
                    *outDataSize = sizeof(AudioObjectID) * 2;
                } else if (IsOutputOrGlobalScope(inAddress->mScope) && inAddress->mScope == kAudioObjectPropertyScopeOutput) {
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
            if (inDataSize < sizeof(UInt32) || inData == NULL) return kAudioHardwareBadPropertySizeError;
            bool active = (*(const UInt32 *)inData) != 0;
            atomic_store(&device->isActive, active);
            atomic_store(&device->isHidden, !active);
            JarvisLoopbackBufferReset(&device->loopback);
            return kAudioHardwareNoError;
        }
        case kJarvisDevicePropertyClearBuffers:
            JarvisLoopbackBufferReset(&device->loopback);
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
    if (previous == 0) {
        *ZeroTimeAnchorFor(device) = mach_absolute_time();
    }
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

    UInt64 anchor = *ZeroTimeAnchorFor(device);
    UInt64 now = mach_absolute_time();
    Float64 elapsedFrames = (Float64)(now - anchor) / gHostTicksPerFrame;
    Float64 periodFrames = (Float64)JARVIS_CALL_AUDIO_ZERO_TIMESTAMP_PERIOD;
    Float64 periods = floor(elapsedFrames / periodFrames);
    Float64 sampleTime = periods * periodFrames;
    UInt64 hostTime = anchor + (UInt64)(sampleTime * gHostTicksPerFrame);

    *outSampleTime = sampleTime; *outHostTime = hostTime; *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus Driver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    Boolean willDo = (inOperationID == kAudioServerPlugInIOOperationReadInput || inOperationID == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo != NULL) *outWillDo = willDo;
    if (outWillDoInPlace != NULL) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus Driver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

/* Real-time IO thread. Never blocks/allocates/logs — JarvisLoopbackBuffer's Read/Write are both
   lock-free and return immediately. WriteMix is the Output stream's "hardware sink" (we capture
   what was written instead of handing it to real hardware); ReadInput is the Input stream's
   "hardware source" (we hand back whatever this same device's Output side produced). This is the
   entire Output->Input loopback — no other code path connects them. */
static OSStatus Driver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inDriver; (void)inClientID; (void)inIOCycleInfo; (void)ioSecondaryBuffer; (void)inStreamObjectID;

    // inDeviceObjectID always identifies the owning device (never a stream ID) per
    // AudioServerPlugIn.h's DoIOOperation contract; inOperationID alone tells us direction.
    JarvisCallAudioDeviceState *device = ResolveObject(inDeviceObjectID, NULL, NULL);
    if (device == NULL || ioMainBuffer == NULL) return kAudioHardwareNoError;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        JarvisLoopbackBufferWrite(&device->loopback, (const float *)ioMainBuffer, inIOBufferFrameSize);
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        JarvisLoopbackBufferRead(&device->loopback, (float *)ioMainBuffer, inIOBufferFrameSize);
    }
    return kAudioHardwareNoError;
}

static OSStatus Driver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}
