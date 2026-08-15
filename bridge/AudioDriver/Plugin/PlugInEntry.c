#include "PlugInTypes.h"

/*
 * CFPlugIn entry point resolved by coreaudiod via the factory UUID mapping declared in
 * Info.plist's CFPlugInFactories. Hands back the single static driver instance built in
 * PlugInInterface.c — there is no support for multiple instances.
 */
void *JarvisCallAudioFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    (void)allocator;

    if (!CFEqual(typeID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }

    return (void *)JarvisCallAudio_GetDriverRef();
}
