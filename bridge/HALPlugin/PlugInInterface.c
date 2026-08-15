#include "PlugInTypes.h"
#include "JarvisVMicRing.h"

#include <CoreFoundation/CFPlugInCOM.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#pragma mark - Device constants

static const CFStringRef kJarvisVMic_DeviceUID = CFSTR("com.jarvis.callbridge.virtualmic");
static const CFStringRef kJarvisVMic_ModelUID = CFSTR("com.jarvis.callbridge.virtualmic.model");
static const CFStringRef kJarvisVMic_DeviceName = CFSTR("Jarvis Virtual Mic");
static const CFStringRef kJarvisVMic_Manufacturer = CFSTR("Jarvis");
static const CFStringRef kJarvisVMic_BundleID = CFSTR("com.jarvis.callbridge.virtualmic");

// Must be >= 10923 per AudioServerPlugIn.h's documented minimum for
// kAudioDevicePropertyZeroTimeStampPeriod. One second at 48kHz comfortably clears that.
static const UInt32 kJarvisVMic_ZeroTimeStampPeriod = JARVIS_VMIC_SAMPLE_RATE;

#pragma mark - Object/interface plumbing

typedef struct {
    AudioServerPlugInDriverInterface *mInterface;
} JarvisVMicDriverObject;

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
    Driver_QueryInterface,
    Driver_AddRef,
    Driver_Release,
    Driver_Initialize,
    Driver_CreateDevice,
    Driver_DestroyDevice,
    Driver_AddDeviceClient,
    Driver_RemoveDeviceClient,
    Driver_PerformDeviceConfigurationChange,
    Driver_AbortDeviceConfigurationChange,
    Driver_HasProperty,
    Driver_IsPropertySettable,
    Driver_GetPropertyDataSize,
    Driver_GetPropertyData,
    Driver_SetPropertyData,
    Driver_StartIO,
    Driver_StopIO,
    Driver_GetZeroTimeStamp,
    Driver_WillDoIOOperation,
    Driver_BeginIOOperation,
    Driver_DoIOOperation,
    Driver_EndIOOperation
};

static JarvisVMicDriverObject gDriverObject = { &gInterface };
static ULONG gRefCount = 1;

AudioServerPlugInDriverRef JarvisVMic_GetDriverRef(void) {
    return &gDriverObject.mInterface;
}

#pragma mark - Global driver state

static AudioServerPlugInHostRef gHost = NULL;
static _Atomic UInt32 gIORunningClientCount = 0; // note: only used with plain loads/stores below (see gRingLock discussion)
static int gShmFD = -1;
static JarvisVMicRing *gRing = NULL;
static UInt64 gZeroTimeAnchorHostTime = 0;
static Float64 gHostTicksPerFrame = 0;

#pragma mark - IUnknown

static OSStatus Driver_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (outInterface == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) {
        return kAudioHardwareUnspecifiedError;
    }

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

static ULONG Driver_AddRef(void *inDriver) {
    (void)inDriver;
    gRefCount += 1;
    return gRefCount;
}

static ULONG Driver_Release(void *inDriver) {
    (void)inDriver;
    if (gRefCount > 0) {
        gRefCount -= 1;
    }
    return gRefCount;
}

#pragma mark - Shared memory lifecycle

// Driver owns creation of the shared-memory ring buffer (O_CREAT). The Jarvis app only ever
// attaches to an already-existing segment (see VirtualMicTXProbe.swift / JarvisVMicRingShmOpenExisting).
// World-readable/writable permissions are required because coreaudiod's daemon user and the
// logged-in user's app process are different UIDs — acceptable for this single-user local PoC
// per the PRD's "1 User = 1 Mac = 1 Bridge" scope, but worth flagging as a hardening item for
// any future multi-user or security-sensitive iteration.
static void SetUpSharedMemory(void) {
    if (gRing != NULL) {
        return;
    }

    int fd = shm_open(JARVIS_VMIC_SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (fd < 0) {
        return;
    }

    size_t size = JarvisVMicRingByteSize();
    struct stat st;
    if (fstat(fd, &st) == 0 && (size_t)st.st_size < size) {
        if (ftruncate(fd, (off_t)size) != 0) {
            close(fd);
            return;
        }
    }

    void *pointer = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pointer == MAP_FAILED) {
        close(fd);
        return;
    }

    gShmFD = fd;
    gRing = (JarvisVMicRing *)pointer;
    if (!JarvisVMicRingHeaderValid(gRing)) {
        JarvisVMicRingInitHeader(gRing);
    }
}

#pragma mark - Basic Operations

static OSStatus Driver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    (void)inDriver;
    gHost = inHost;
    SetUpSharedMemory();

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    // host ticks per second = 1e9 * timebase.denom / timebase.numer; ticks per frame = that / sampleRate
    Float64 hostTicksPerSecond = 1000000000.0 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = hostTicksPerSecond / (Float64)JARVIS_VMIC_SAMPLE_RATE;
    gZeroTimeAnchorHostTime = mach_absolute_time();

    return kAudioHardwareNoError;
}

// This driver publishes a single static device at load time; it does not support the host
// dynamically creating/destroying additional device instances.
static OSStatus Driver_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Driver_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Driver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus Driver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

// This device never calls RequestDeviceConfigurationChange() itself (fixed format, fixed
// structure), so these should never be invoked in practice; they are no-ops for completeness.
static OSStatus Driver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static OSStatus Driver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

#pragma mark - Format helpers

static void FillStreamFormat(AudioStreamBasicDescription *format) {
    memset(format, 0, sizeof(AudioStreamBasicDescription));
    format->mSampleRate = (Float64)JARVIS_VMIC_SAMPLE_RATE;
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format->mBytesPerPacket = sizeof(Float32) * JARVIS_VMIC_CHANNEL_COUNT;
    format->mFramesPerPacket = 1;
    format->mBytesPerFrame = sizeof(Float32) * JARVIS_VMIC_CHANNEL_COUNT;
    format->mChannelsPerFrame = JARVIS_VMIC_CHANNEL_COUNT;
    format->mBitsPerChannel = 32;
}

#pragma mark - Property Operations

static Boolean IsInputOrGlobalScope(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput;
}

static Boolean Driver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL) {
        return false;
    }

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
            return true;
        default:
            break;
    }

    if (inObjectID == kAudioObjectPlugInObject) {
        switch (inAddress->mSelector) {
            case kAudioPlugInPropertyBundleID:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
                return true;
            default:
                return false;
        }
    }

    if (inObjectID == kJarvisVMic_Device_ObjectID) {
        switch (inAddress->mSelector) {
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
                return true;
            default:
                return false;
        }
    }

    if (inObjectID == kJarvisVMic_Stream_ObjectID) {
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
            default:
                return false;
        }
    }

    return false;
}

static OSStatus Driver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inDriver; (void)inClientProcessID; (void)inObjectID; (void)inAddress;
    if (outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    // Nothing is settable in this Phase 0 spike — fixed format, no controls, no persisted state.
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

static OSStatus Driver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            if (inObjectID == kAudioObjectPlugInObject) {
                *outDataSize = sizeof(AudioObjectID) * 1;
            } else if (inObjectID == kJarvisVMic_Device_ObjectID) {
                *outDataSize = sizeof(AudioObjectID) * 1;
            } else {
                *outDataSize = 0;
            }
            return kAudioHardwareNoError;
        default:
            break;
    }

    if (inObjectID == kAudioObjectPlugInObject) {
        switch (inAddress->mSelector) {
            case kAudioPlugInPropertyBundleID:
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioPlugInPropertyDeviceList:
                *outDataSize = sizeof(AudioObjectID) * 1;
                return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToDevice:
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kJarvisVMic_Device_ObjectID) {
        switch (inAddress->mSelector) {
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
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
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyRelatedDevices:
                *outDataSize = sizeof(AudioObjectID) * 1;
                return kAudioHardwareNoError;
            case kAudioDevicePropertyStreams:
                *outDataSize = IsInputOrGlobalScope(inAddress->mScope) ? sizeof(AudioObjectID) * 1 : 0;
                return kAudioHardwareNoError;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0; // no controls
                return kAudioHardwareNoError;
            case kAudioDevicePropertyNominalSampleRate:
                *outDataSize = sizeof(Float64);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                *outDataSize = sizeof(AudioValueRange) * 1;
                return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kJarvisVMic_Stream_ObjectID) {
        switch (inAddress->mSelector) {
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *outDataSize = sizeof(AudioStreamBasicDescription);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                *outDataSize = sizeof(AudioStreamRangedDescription) * 1;
                return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

static OSStatus Driver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    // AudioObject base properties, common across all three of our objects.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID *)outData = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyClass:
            if (inDataSize < sizeof(AudioClassID)) return kAudioHardwareBadPropertySizeError;
            *(AudioClassID *)outData = (inObjectID == kAudioObjectPlugInObject) ? kAudioPlugInClassID
                : (inObjectID == kJarvisVMic_Device_ObjectID) ? kAudioDeviceClassID
                : kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *(AudioObjectID *)outData = (inObjectID == kAudioObjectPlugInObject) ? kAudioObjectUnknown
                : (inObjectID == kJarvisVMic_Device_ObjectID) ? (AudioObjectID)kAudioObjectPlugInObject
                : (AudioObjectID)kJarvisVMic_Device_ObjectID;
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = (inObjectID == kJarvisVMic_Device_ObjectID) ? kJarvisVMic_DeviceName
                : (inObjectID == kJarvisVMic_Stream_ObjectID) ? kJarvisVMic_DeviceName
                : kJarvisVMic_Manufacturer;
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *(CFStringRef *)outData = kJarvisVMic_Manufacturer;
            *outDataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            if (inObjectID == kAudioObjectPlugInObject) {
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                ((AudioObjectID *)outData)[0] = kJarvisVMic_Device_ObjectID;
                *outDataSize = sizeof(AudioObjectID);
            } else if (inObjectID == kJarvisVMic_Device_ObjectID) {
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                ((AudioObjectID *)outData)[0] = kJarvisVMic_Stream_ObjectID;
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return kAudioHardwareNoError;
        default:
            break;
    }

    if (inObjectID == kAudioObjectPlugInObject) {
        switch (inAddress->mSelector) {
            case kAudioPlugInPropertyBundleID:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = kJarvisVMic_BundleID;
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioPlugInPropertyDeviceList:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                ((AudioObjectID *)outData)[0] = kJarvisVMic_Device_ObjectID;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                if (inQualifierDataSize < sizeof(CFStringRef) || inQualifierData == NULL) {
                    return kAudioHardwareIllegalOperationError;
                }
                CFStringRef uid = *(const CFStringRef *)inQualifierData;
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                *(AudioObjectID *)outData = (uid != NULL && CFEqual(uid, kJarvisVMic_DeviceUID))
                    ? kJarvisVMic_Device_ObjectID : kAudioObjectUnknown;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kJarvisVMic_Device_ObjectID) {
        switch (inAddress->mSelector) {
            case kAudioDevicePropertyDeviceUID:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = kJarvisVMic_DeviceUID;
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyModelUID:
                if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)outData = kJarvisVMic_ModelUID;
                *outDataSize = sizeof(CFStringRef);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyTransportType:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyClockDomain:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 0;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsAlive:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 1;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsRunning:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = (gIORunningClientCount > 0) ? 1 : 0;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = IsInputOrGlobalScope(inAddress->mScope) ? 1 : 0;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 0;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = kJarvisVMic_ZeroTimeStampPeriod;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyIsHidden:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 0;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyRelatedDevices:
                if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                ((AudioObjectID *)outData)[0] = kJarvisVMic_Device_ObjectID;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyStreams:
                if (IsInputOrGlobalScope(inAddress->mScope)) {
                    if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
                    ((AudioObjectID *)outData)[0] = kJarvisVMic_Stream_ObjectID;
                    *outDataSize = sizeof(AudioObjectID);
                } else {
                    *outDataSize = 0;
                }
                return kAudioHardwareNoError;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0; // no controls implemented
                return kAudioHardwareNoError;
            case kAudioDevicePropertyNominalSampleRate:
                if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
                *(Float64 *)outData = (Float64)JARVIS_VMIC_SAMPLE_RATE;
                *outDataSize = sizeof(Float64);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
                ((AudioValueRange *)outData)[0].mMinimum = (Float64)JARVIS_VMIC_SAMPLE_RATE;
                ((AudioValueRange *)outData)[0].mMaximum = (Float64)JARVIS_VMIC_SAMPLE_RATE;
                *outDataSize = sizeof(AudioValueRange);
                return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kJarvisVMic_Stream_ObjectID) {
        switch (inAddress->mSelector) {
            case kAudioStreamPropertyIsActive:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 1;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyDirection:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 1; // 1 == input stream
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyTerminalType:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = kAudioStreamTerminalTypeMicrophone;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyStartingChannel:
                if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)outData = 1;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                FillStreamFormat((AudioStreamBasicDescription *)outData);
                *outDataSize = sizeof(AudioStreamBasicDescription);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                if (inDataSize < sizeof(AudioStreamRangedDescription)) return kAudioHardwareBadPropertySizeError;
                AudioStreamRangedDescription *ranged = (AudioStreamRangedDescription *)outData;
                FillStreamFormat(&ranged->mFormat);
                ranged->mSampleRateRange.mMinimum = (Float64)JARVIS_VMIC_SAMPLE_RATE;
                ranged->mSampleRateRange.mMaximum = (Float64)JARVIS_VMIC_SAMPLE_RATE;
                *outDataSize = sizeof(AudioStreamRangedDescription);
                return kAudioHardwareNoError;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

static OSStatus Driver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inDriver; (void)inObjectID; (void)inClientProcessID; (void)inAddress;
    (void)inQualifierDataSize; (void)inQualifierData; (void)inDataSize; (void)inData;
    // Nothing is settable in this Phase 0 spike.
    return kAudioHardwareUnsupportedOperationError;
}

#pragma mark - IO Operations

static OSStatus Driver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    gIORunningClientCount += 1;
    return kAudioHardwareNoError;
}

static OSStatus Driver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    if (gIORunningClientCount > 0) {
        gIORunningClientCount -= 1;
    }
    return kAudioHardwareNoError;
}

static OSStatus Driver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    UInt64 now = mach_absolute_time();
    Float64 elapsedFrames = (Float64)(now - gZeroTimeAnchorHostTime) / gHostTicksPerFrame;
    Float64 periodFrames = (Float64)kJarvisVMic_ZeroTimeStampPeriod;
    Float64 periods = floor(elapsedFrames / periodFrames);
    Float64 sampleTime = periods * periodFrames;
    UInt64 hostTime = gZeroTimeAnchorHostTime + (UInt64)(sampleTime * gHostTicksPerFrame);

    *outSampleTime = sampleTime;
    *outHostTime = hostTime;
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus Driver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    Boolean willDo = (inOperationID == kAudioServerPlugInIOOperationReadInput);
    if (outWillDo != NULL) *outWillDo = willDo;
    if (outWillDoInPlace != NULL) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus Driver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

// Real-time IO thread. Must not block, allocate, or log — see JarvisVMicRing.h's read helper,
// which is lock-free and always returns immediately (silence-fills and counts underruns instead
// of waiting for data).
static OSStatus Driver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inDriver; (void)inDeviceObjectID; (void)inStreamObjectID; (void)inClientID; (void)inIOCycleInfo; (void)ioSecondaryBuffer;

    if (inOperationID != kAudioServerPlugInIOOperationReadInput || ioMainBuffer == NULL) {
        return kAudioHardwareNoError;
    }

    if (gRing == NULL) {
        memset(ioMainBuffer, 0, (size_t)inIOBufferFrameSize * sizeof(Float32));
        return kAudioHardwareNoError;
    }

    JarvisVMicRingRead(gRing, (Float32 *)ioMainBuffer, inIOBufferFrameSize);
    return kAudioHardwareNoError;
}

static OSStatus Driver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}
