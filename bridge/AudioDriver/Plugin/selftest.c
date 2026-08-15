#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>

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
    Check("device can NEVER be default device (safety invariant)", canDefault == 0);

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

    // kAudioObjectPropertyCustomPropertyInfoList: the documented discovery mechanism a generic
    // client can use to learn our custom properties' marshaling types without hardcoding them.
    AudioObjectPropertyAddress customListAddress = { kAudioObjectPropertyCustomPropertyInfoList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioServerPlugInCustomPropertyInfo customInfo[2];
    status = interface->GetPropertyData(driverRef, deviceID, 0, &customListAddress, 0, NULL, sizeof(customInfo), &outSize, customInfo);
    Check("GetPropertyData(CustomPropertyInfoList) succeeds", status == kAudioHardwareNoError);
    Check("CustomPropertyInfoList reports 2 entries", outSize == sizeof(customInfo));
    if (status == kAudioHardwareNoError) {
        Check("CustomPropertyInfoList[0] is Active/CFPropertyList",
              customInfo[0].mSelector == kJarvisDevicePropertyActive &&
              customInfo[0].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    }
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
    // queries — device UID/name and the loopback buffers are only set up inside it. inHost is
    // never dereferenced by this driver's Initialize (see PlugInInterface.c), so an all-zero
    // dummy host interface is safe here (its non-null address just satisfies the header's
    // nonnull annotation without ever being called into).
    AudioServerPlugInHostInterface dummyHost = { 0 };
    status = interface->Initialize(driverRef, &dummyHost);
    Check("Initialize(driverRef, dummyHost) succeeds", status == kAudioHardwareNoError);

    printf("\n--- PlugIn ---\n");
    UInt32 outSize;
    AudioObjectPropertyAddress deviceListAddress = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectID deviceList[2] = { 0, 0 };
    status = interface->GetPropertyData(driverRef, kAudioObjectPlugInObject, 0, &deviceListAddress, 0, NULL, sizeof(deviceList), &outSize, deviceList);
    Check("GetPropertyData(PlugIn, DeviceList) succeeds", status == kAudioHardwareNoError);
    Check("DeviceList has exactly 2 devices", outSize == sizeof(AudioObjectID) * 2);
    printf("  devices = [%u, %u]\n", (unsigned)deviceList[0], (unsigned)deviceList[1]);

    printf("\n--- Jarvis Call Capture ---\n");
    CheckDevice(interface, driverRef, kJarvisCallAudio_Capture_Device, kJarvisCallAudio_Capture_OutputStream, kJarvisCallAudio_Capture_InputStream, "com.jarvis.callbridge.audio.capture");

    printf("\n--- Jarvis Call Inject ---\n");
    CheckDevice(interface, driverRef, kJarvisCallAudio_Inject_Device, kJarvisCallAudio_Inject_OutputStream, kJarvisCallAudio_Inject_InputStream, "com.jarvis.callbridge.audio.inject");

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
        Check("Capture independent state: activating Capture only affects Capture", captureAfter == kCFBooleanTrue && injectAfter == kCFBooleanFalse);

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
