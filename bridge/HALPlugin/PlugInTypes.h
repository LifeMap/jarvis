#ifndef JARVIS_VMIC_PLUGIN_TYPES_H
#define JARVIS_VMIC_PLUGIN_TYPES_H

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

/*
 * CB Phase 0-B "Jarvis Virtual Mic" HAL Audio Server Plug-in.
 *
 * Minimal, deliberately stripped-down object model: one PlugIn object, one
 * static input-only Device, one Stream. No Controls (no volume/mute), no
 * aggregate-device support, no dynamic CreateDevice/DestroyDevice. Modeled
 * structurally on Apple's publicly documented AudioServerPlugIn.h interface
 * (see CoreAudio/AudioServerPlugIn.h) and the object-model shape described
 * in Apple's "Creating an Audio Server Driver Plug-in" article, which the
 * PRD's appendix references.
 *
 * Audio is delivered via the shared-memory ring buffer defined in
 * JarvisVMicRing.h — the Jarvis Call Bridge app is the producer, this
 * driver's DoIOOperation is the consumer, running on a real-time IO thread
 * inside coreaudiod (a different process from the app).
 */

// Fixed AudioObjectIDs for this plug-in's static object graph.
// kAudioObjectPlugInObject (1) is mandated by the AudioServerPlugIn contract.
enum {
    kJarvisVMic_Device_ObjectID = 2,
    kJarvisVMic_Stream_ObjectID = 3
};

// The factory function referenced by Info.plist's CFPlugInFactories.
void *JarvisVMicFactory(CFAllocatorRef allocator, CFUUIDRef typeID);

// Returns the singleton driver interface reference used by the factory function.
AudioServerPlugInDriverRef JarvisVMic_GetDriverRef(void);

#endif /* JARVIS_VMIC_PLUGIN_TYPES_H */
