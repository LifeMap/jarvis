#include "PlugInTypes.h"

/*
 * CFPlugIn entry point. The host (coreaudiod) resolves this symbol by name
 * via the factory UUID mapping declared in Info.plist's CFPlugInFactories,
 * and calls it once per requested plug-in type. We only ever hand back one
 * static driver instance (the "Jarvis Virtual Mic" object graph built in
 * PlugInInterface.c) — there is no support for multiple instances.
 */
void *JarvisVMicFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    (void)allocator;

    if (!CFEqual(typeID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }

    return (void *)JarvisVMic_GetDriverRef();
}
