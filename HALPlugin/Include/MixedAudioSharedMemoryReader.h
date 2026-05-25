#ifndef MIXED_AUDIO_SHARED_MEMORY_READER_H
#define MIXED_AUDIO_SHARED_MEMORY_READER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "MixedAudioSharedMemory.h"

typedef enum mixed_audio_shm_reader_status {
    MIXED_AUDIO_SHM_READER_OK = 0,
    MIXED_AUDIO_SHM_READER_MISSING,
    MIXED_AUDIO_SHM_READER_OPEN_FAILED,
    MIXED_AUDIO_SHM_READER_STAT_FAILED,
    MIXED_AUDIO_SHM_READER_MAP_FAILED,
    MIXED_AUDIO_SHM_READER_INVALID_HEADER,
    MIXED_AUDIO_SHM_READER_NOT_MAPPED,
    MIXED_AUDIO_SHM_READER_UNDERRUN,
    MIXED_AUDIO_SHM_READER_OVERRUN,
    MIXED_AUDIO_SHM_READER_GENERATION_CHANGED,
    MIXED_AUDIO_SHM_READER_STALE_HEARTBEAT
} mixed_audio_shm_reader_status_t;

typedef struct mixed_audio_shm_reader {
    mixed_audio_shm_header_t *header;
    size_t byte_count;
    uint64_t local_generation;
    uint64_t local_read_frame_index;
    dev_t mapped_device;
    ino_t mapped_inode;
    int last_errno;
    bool can_write_header;
} mixed_audio_shm_reader_t;

void mixed_audio_shm_reader_init(mixed_audio_shm_reader_t *reader);
void mixed_audio_shm_reader_close(mixed_audio_shm_reader_t *reader);
mixed_audio_shm_reader_status_t mixed_audio_shm_reader_open(mixed_audio_shm_reader_t *reader,
                                                            const char *name);
mixed_audio_shm_reader_status_t mixed_audio_shm_reader_reopen_if_changed(mixed_audio_shm_reader_t *reader,
                                                                         const char *name);
mixed_audio_shm_reader_status_t mixed_audio_shm_reader_read(mixed_audio_shm_reader_t *reader,
                                                            float *output_frames,
                                                            uint32_t requested_frames,
                                                            uint32_t *out_copied_frames);
mixed_audio_shm_reader_status_t mixed_audio_shm_reader_read_at_time(mixed_audio_shm_reader_t *reader,
                                                                    float *output_frames,
                                                                    uint32_t requested_frames,
                                                                    uint64_t now_nanos,
                                                                    uint32_t *out_copied_frames);
const char *mixed_audio_shm_reader_status_string(mixed_audio_shm_reader_status_t status);

#endif
