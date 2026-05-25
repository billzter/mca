#ifndef MIXED_AUDIO_SHARED_MEMORY_PROBE_H
#define MIXED_AUDIO_SHARED_MEMORY_PROBE_H

#include <stdint.h>
#include <stddef.h>

#include "MixedAudioSharedMemory.h"

typedef enum mixed_audio_shm_probe_status {
    MIXED_AUDIO_SHM_PROBE_OK = 0,
    MIXED_AUDIO_SHM_PROBE_MISSING = 1,
    MIXED_AUDIO_SHM_PROBE_OPEN_FAILED = 2,
    MIXED_AUDIO_SHM_PROBE_STAT_FAILED = 3,
    MIXED_AUDIO_SHM_PROBE_MAP_FAILED = 4,
    MIXED_AUDIO_SHM_PROBE_INVALID_HEADER = 5,
    MIXED_AUDIO_SHM_PROBE_NO_FRAMES = 6
} mixed_audio_shm_probe_status_t;

typedef struct mixed_audio_shm_probe_result {
    mixed_audio_shm_probe_status_t status;
    int error_number;
    uint32_t capacity_frames;
    uint64_t generation;
    uint64_t write_frame_index;
    uint64_t heartbeat_nanos;
    float marker_left;
    float marker_right;
} mixed_audio_shm_probe_result_t;

mixed_audio_shm_probe_result_t mixed_audio_shm_probe(const char *shm_name);
const char *mixed_audio_shm_probe_status_string(mixed_audio_shm_probe_status_t status);

#endif
