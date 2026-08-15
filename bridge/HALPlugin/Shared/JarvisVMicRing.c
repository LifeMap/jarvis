#include "JarvisVMicRing.h"

#include <fcntl.h>
#include <sys/mman.h>

const char *JarvisVMicRingVersionString(void) {
    return "jarvis-vmic-ring-1";
}

int JarvisVMicRingShmOpenExisting(const char *name) {
    return shm_open(name, O_RDWR);
}
