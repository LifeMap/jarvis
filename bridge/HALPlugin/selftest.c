#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>

/*
 * CB Phase 0-B optional verification rung: dlopen()s the built driver bundle Mach-O directly and
 * exercises its factory function + a few QueryInterface/GetPropertyData calls IN-PROCESS —
 * without coreaudiod, without sudo, without installing anything, without a real device. This
 * proves "the vtable links and answers basic queries correctly" as a distinct, weaker claim than
 * "coreaudiod actually loaded it" (requires install.sh, not run here) or "Phone.app actually used
 * it" (requires a real call). Never conflate this pass with either of those.
 */

typedef void *(*FactoryFunc)(CFAllocatorRef, CFUUIDRef);

static void PrintCFString(const char *label, CFStringRef value) {
    if (value == NULL) {
        printf("%s = (null)\n", label);
        return;
    }
    char buffer[256];
    if (CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        printf("%s = %s\n", label, buffer);
    } else {
        printf("%s = (unreadable CFString)\n", label);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <path-to-driver-bundle-executable>\n", argv[0]);
        return 1;
    }

    void *handle = dlopen(argv[1], RTLD_NOW);
    if (handle == NULL) {
        fprintf(stderr, "FAIL: dlopen failed: %s\n", dlerror());
        return 1;
    }

    FactoryFunc factory = (FactoryFunc)dlsym(handle, "JarvisVMicFactory");
    if (factory == NULL) {
        fprintf(stderr, "FAIL: dlsym(JarvisVMicFactory) failed: %s\n", dlerror());
        return 1;
    }

    void *ref = factory(NULL, kAudioServerPlugInTypeUUID);
    if (ref == NULL) {
        fprintf(stderr, "FAIL: factory returned NULL for kAudioServerPlugInTypeUUID\n");
        return 1;
    }
    printf("PASS: factory returned a driver ref (%p)\n", ref);

    AudioServerPlugInDriverRef driverRef = (AudioServerPlugInDriverRef)ref;
    AudioServerPlugInDriverInterface *interface = *driverRef;

    void *queried = NULL;
    CFUUIDBytes driverInterfaceUUIDBytes = CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID);
    OSStatus status = interface->QueryInterface(driverRef, driverInterfaceUUIDBytes, &queried);
    printf("%s: QueryInterface(kAudioServerPlugInDriverInterfaceUUID) status=%d\n",
           (status == kAudioHardwareNoError && queried != NULL) ? "PASS" : "FAIL", (int)status);

    AudioObjectPropertyAddress manufacturerAddress = {
        kAudioObjectPropertyManufacturer, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    CFStringRef manufacturer = NULL;
    UInt32 outSize = 0;
    status = interface->GetPropertyData(driverRef, kAudioObjectPlugInObject, 0, &manufacturerAddress,
                                         0, NULL, sizeof(manufacturer), &outSize, &manufacturer);
    printf("%s: GetPropertyData(PlugIn, Manufacturer) status=%d\n",
           (status == kAudioHardwareNoError) ? "PASS" : "FAIL", (int)status);
    PrintCFString("  Manufacturer", manufacturer);

    AudioObjectPropertyAddress uidAddress = {
        kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    CFStringRef deviceUID = NULL;
    status = interface->GetPropertyData(driverRef, 2 /* kJarvisVMic_Device_ObjectID */, 0, &uidAddress,
                                         0, NULL, sizeof(deviceUID), &outSize, &deviceUID);
    printf("%s: GetPropertyData(Device, DeviceUID) status=%d\n",
           (status == kAudioHardwareNoError) ? "PASS" : "FAIL", (int)status);
    PrintCFString("  DeviceUID", deviceUID);

    AudioObjectPropertyAddress formatAddress = {
        kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    AudioStreamBasicDescription format;
    status = interface->GetPropertyData(driverRef, 3 /* kJarvisVMic_Stream_ObjectID */, 0, &formatAddress,
                                         0, NULL, sizeof(format), &outSize, &format);
    printf("%s: GetPropertyData(Stream, VirtualFormat) status=%d\n",
           (status == kAudioHardwareNoError) ? "PASS" : "FAIL", (int)status);
    if (status == kAudioHardwareNoError) {
        printf("  sampleRate=%.0f channels=%u bitsPerChannel=%u bytesPerFrame=%u\n",
               format.mSampleRate, (unsigned)format.mChannelsPerFrame,
               (unsigned)format.mBitsPerChannel, (unsigned)format.mBytesPerFrame);
    }

    printf("\nselftest completed WITHOUT coreaudiod, WITHOUT sudo, WITHOUT a real device.\n");
    printf("This proves the vtable links and answers basic property queries — it does NOT prove\n");
    printf("coreaudiod will load it, or that Phone.app/a real caller will see real audio.\n");
    return 0;
}
