#ifndef MIXED_CAPTURE_AUDIO_COMPATIBILITY_H
#define MIXED_CAPTURE_AUDIO_COMPATIBILITY_H

#include <CoreAudio/AudioHardware.h>
#include <stdint.h>

#include "MixedAudioSharedMemory.h"

#define MCA_FOURCC(a, b, c, d) \
    ((AudioObjectPropertySelector)((((uint32_t)(a)) << 24) | (((uint32_t)(b)) << 16) | (((uint32_t)(c)) << 8) | ((uint32_t)(d))))

#define MCA_DRIVER_COMPATIBILITY_VERSION 1u
#define MCA_SHARED_MEMORY_ABI_VERSION MIXED_AUDIO_ABI_VERSION
#define MCA_DRIVER_MODEL_UID "com.minamiktr.mca.model.MixedCaptureAudio.driver1.shm1"

#define MCA_INFO_PLIST_DRIVER_COMPATIBILITY_KEY "MCAHALCompatibilityVersion"
#define MCA_INFO_PLIST_SHARED_MEMORY_ABI_KEY "MCASharedMemoryABIVersion"

#define kMCAAudioDevicePropertyDriverCompatibilityVersion MCA_FOURCC('m', 'c', 'a', 'v')
#define kMCAAudioDevicePropertySharedMemoryABIVersion MCA_FOURCC('m', 'a', 'b', 'i')

#endif
