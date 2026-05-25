#include "MixedAudioSharedMemoryProbe.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static mixed_audio_shm_probe_result_t probe_result(mixed_audio_shm_probe_status_t status,
                                                   int error_number)
{
    mixed_audio_shm_probe_result_t result;
    memset(&result, 0, sizeof(result));
    result.status = status;
    result.error_number = error_number;
    return result;
}

const char *mixed_audio_shm_probe_status_string(mixed_audio_shm_probe_status_t status)
{
    switch (status) {
        case MIXED_AUDIO_SHM_PROBE_OK:
            return "ok";
        case MIXED_AUDIO_SHM_PROBE_MISSING:
            return "missing";
        case MIXED_AUDIO_SHM_PROBE_OPEN_FAILED:
            return "open_failed";
        case MIXED_AUDIO_SHM_PROBE_STAT_FAILED:
            return "stat_failed";
        case MIXED_AUDIO_SHM_PROBE_MAP_FAILED:
            return "map_failed";
        case MIXED_AUDIO_SHM_PROBE_INVALID_HEADER:
            return "invalid_header";
        case MIXED_AUDIO_SHM_PROBE_NO_FRAMES:
            return "no_frames";
        default:
            return "unknown";
    }
}

mixed_audio_shm_probe_result_t mixed_audio_shm_probe(const char *shm_name)
{
    if (shm_name == NULL || shm_name[0] == '\0') {
        return probe_result(MIXED_AUDIO_SHM_PROBE_OPEN_FAILED, EINVAL);
    }

    int fd = shm_open(shm_name, O_RDONLY, 0);
    if (fd < 0) {
        int open_errno = errno;
        if (open_errno == ENOENT) {
            return probe_result(MIXED_AUDIO_SHM_PROBE_MISSING, open_errno);
        }
        return probe_result(MIXED_AUDIO_SHM_PROBE_OPEN_FAILED, open_errno);
    }

    struct stat stat_buffer;
    if (fstat(fd, &stat_buffer) != 0) {
        int stat_errno = errno;
        close(fd);
        return probe_result(MIXED_AUDIO_SHM_PROBE_STAT_FAILED, stat_errno);
    }
    if (stat_buffer.st_size < (off_t)mixed_audio_shm_total_byte_count(1)) {
        close(fd);
        return probe_result(MIXED_AUDIO_SHM_PROBE_INVALID_HEADER, 0);
    }

    size_t byte_count = (size_t)stat_buffer.st_size;
    void *mapping = mmap(NULL, byte_count, PROT_READ, MAP_SHARED, fd, 0);
    int map_errno = errno;
    close(fd);
    if (mapping == MAP_FAILED) {
        return probe_result(MIXED_AUDIO_SHM_PROBE_MAP_FAILED, map_errno);
    }

    const mixed_audio_shm_header_t *header = (const mixed_audio_shm_header_t *)mapping;
    mixed_audio_shm_probe_result_t result = probe_result(MIXED_AUDIO_SHM_PROBE_OK, 0);
    result.capacity_frames = header->capacity_frames;
    result.generation = atomic_load(&header->generation);
    result.write_frame_index = atomic_load(&header->write_frame_index);
    result.heartbeat_nanos = atomic_load(&header->producer_heartbeat_nanos);

    if (header->magic != MIXED_AUDIO_SHM_MAGIC ||
        header->version != MIXED_AUDIO_SHM_VERSION ||
        header->sample_rate != MIXED_AUDIO_OUTPUT_SAMPLE_RATE ||
        header->channel_count != MIXED_AUDIO_OUTPUT_CHANNEL_COUNT ||
        header->capacity_frames == 0 ||
        header->target_shared_fill_frames != MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES ||
        byte_count < mixed_audio_shm_total_byte_count(header->capacity_frames)) {
        munmap(mapping, byte_count);
        result.status = MIXED_AUDIO_SHM_PROBE_INVALID_HEADER;
        return result;
    }

    if (result.generation == 0 || result.heartbeat_nanos == 0 || result.write_frame_index == 0) {
        munmap(mapping, byte_count);
        result.status = MIXED_AUDIO_SHM_PROBE_NO_FRAMES;
        return result;
    }

    const float *frames = mixed_audio_shm_const_frames(header);
    result.marker_left = frames[0];
    result.marker_right = frames[1];
    munmap(mapping, byte_count);
    return result;
}
