#include "MixedAudioSharedMemoryReader.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static void zero_frames(float *output_frames, uint32_t frame_count)
{
    if (output_frames != NULL && frame_count > 0) {
        memset(output_frames, 0, mixed_audio_shm_frame_byte_count(frame_count));
    }
}

static bool has_valid_header(const mixed_audio_shm_header_t *header, size_t byte_count)
{
    if (header == NULL) {
        return false;
    }
    if (byte_count < sizeof(mixed_audio_shm_header_t)) {
        return false;
    }
    if (header->magic != MIXED_AUDIO_SHM_MAGIC ||
        header->version != MIXED_AUDIO_SHM_VERSION ||
        header->sample_rate != MIXED_AUDIO_OUTPUT_SAMPLE_RATE ||
        header->channel_count != MIXED_AUDIO_OUTPUT_CHANNEL_COUNT ||
        header->capacity_frames == 0 ||
        header->target_shared_fill_frames != MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES) {
        return false;
    }
    return byte_count >= mixed_audio_shm_total_byte_count(header->capacity_frames);
}

static mixed_audio_shm_reader_status_t map_open_fd(mixed_audio_shm_reader_t *reader,
                                                   int fd,
                                                   bool can_write,
                                                   const struct stat *info)
{
    int protection = PROT_READ | (can_write ? PROT_WRITE : 0);
    void *mapping = mmap(NULL, (size_t)info->st_size, protection, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) {
        reader->last_errno = errno;
        return MIXED_AUDIO_SHM_READER_MAP_FAILED;
    }

    mixed_audio_shm_header_t *header = (mixed_audio_shm_header_t *)mapping;
    if (!has_valid_header(header, (size_t)info->st_size)) {
        munmap(mapping, (size_t)info->st_size);
        return MIXED_AUDIO_SHM_READER_INVALID_HEADER;
    }

    mixed_audio_shm_reader_close(reader);
    reader->header = header;
    reader->byte_count = (size_t)info->st_size;
    reader->can_write_header = can_write;
    reader->mapped_device = info->st_dev;
    reader->mapped_inode = info->st_ino;

    uint64_t write_frame_index =
        atomic_load_explicit(&reader->header->write_frame_index, memory_order_acquire);
    uint32_t capacity_frames = reader->header->capacity_frames;
    reader->local_generation =
        atomic_load_explicit(&reader->header->generation, memory_order_acquire);
    reader->local_read_frame_index =
        write_frame_index > capacity_frames ? write_frame_index - capacity_frames : 0;

    if (reader->can_write_header) {
        atomic_store_explicit(&reader->header->read_frame_index,
                              reader->local_read_frame_index,
                              memory_order_release);
    }

    return MIXED_AUDIO_SHM_READER_OK;
}

static mixed_audio_shm_reader_status_t open_fd(const char *name,
                                               int *out_fd,
                                               bool *out_can_write,
                                               struct stat *out_info,
                                               int *out_errno)
{
    bool can_write = true;
    int fd = shm_open(name, O_RDWR, 0);
    if (fd < 0 && errno == EACCES) {
        can_write = false;
        fd = shm_open(name, O_RDONLY, 0);
    }
    if (fd < 0) {
        *out_errno = errno;
        return errno == ENOENT ? MIXED_AUDIO_SHM_READER_MISSING : MIXED_AUDIO_SHM_READER_OPEN_FAILED;
    }
    if (fstat(fd, out_info) != 0) {
        *out_errno = errno;
        close(fd);
        return MIXED_AUDIO_SHM_READER_STAT_FAILED;
    }

    *out_fd = fd;
    *out_can_write = can_write;
    *out_errno = 0;
    return MIXED_AUDIO_SHM_READER_OK;
}

void mixed_audio_shm_reader_init(mixed_audio_shm_reader_t *reader)
{
    if (reader == NULL) {
        return;
    }
    memset(reader, 0, sizeof(*reader));
}

void mixed_audio_shm_reader_close(mixed_audio_shm_reader_t *reader)
{
    if (reader == NULL) {
        return;
    }
    if (reader->header != NULL) {
        munmap(reader->header, reader->byte_count);
    }
    mixed_audio_shm_reader_init(reader);
}

mixed_audio_shm_reader_status_t mixed_audio_shm_reader_open(mixed_audio_shm_reader_t *reader,
                                                            const char *name)
{
    if (reader == NULL || name == NULL) {
        return MIXED_AUDIO_SHM_READER_OPEN_FAILED;
    }

    mixed_audio_shm_reader_close(reader);

    struct stat info;
    bool can_write = false;
    int fd = -1;
    int error_number = 0;
    mixed_audio_shm_reader_status_t status =
        open_fd(name, &fd, &can_write, &info, &error_number);
    if (status != MIXED_AUDIO_SHM_READER_OK) {
        reader->last_errno = error_number;
        return status;
    }

    status = map_open_fd(reader, fd, can_write, &info);
    close(fd);
    return status;
}

mixed_audio_shm_reader_status_t mixed_audio_shm_reader_read(mixed_audio_shm_reader_t *reader,
                                                            float *output_frames,
                                                            uint32_t requested_frames,
                                                            uint32_t *out_copied_frames)
{
    return mixed_audio_shm_reader_read_at_time(reader, output_frames, requested_frames, 0, out_copied_frames);
}

mixed_audio_shm_reader_status_t mixed_audio_shm_reader_reopen_if_changed(mixed_audio_shm_reader_t *reader,
                                                                         const char *name)
{
    if (reader == NULL || name == NULL) {
        return MIXED_AUDIO_SHM_READER_OPEN_FAILED;
    }

    struct stat info;
    bool can_write = false;
    int fd = -1;
    int error_number = 0;
    mixed_audio_shm_reader_status_t status =
        open_fd(name, &fd, &can_write, &info, &error_number);
    if (status != MIXED_AUDIO_SHM_READER_OK) {
        reader->last_errno = error_number;
        if (status == MIXED_AUDIO_SHM_READER_MISSING) {
            mixed_audio_shm_reader_close(reader);
        }
        return status;
    }

    status = map_open_fd(reader, fd, can_write, &info);
    close(fd);
    return status;
}

mixed_audio_shm_reader_status_t mixed_audio_shm_reader_read_at_time(mixed_audio_shm_reader_t *reader,
                                                                    float *output_frames,
                                                                    uint32_t requested_frames,
                                                                    uint64_t now_nanos,
                                                                    uint32_t *out_copied_frames)
{
    if (out_copied_frames != NULL) {
        *out_copied_frames = 0;
    }
    if (output_frames == NULL || requested_frames == 0) {
        return MIXED_AUDIO_SHM_READER_OK;
    }
    if (reader == NULL || reader->header == NULL) {
        zero_frames(output_frames, requested_frames);
        return MIXED_AUDIO_SHM_READER_NOT_MAPPED;
    }
    if (!has_valid_header(reader->header, reader->byte_count)) {
        zero_frames(output_frames, requested_frames);
        return MIXED_AUDIO_SHM_READER_INVALID_HEADER;
    }

    uint64_t generation = atomic_load_explicit(&reader->header->generation, memory_order_acquire);
    uint64_t write_frame_index =
        atomic_load_explicit(&reader->header->write_frame_index, memory_order_acquire);
    uint64_t heartbeat_nanos =
        atomic_load_explicit(&reader->header->producer_heartbeat_nanos, memory_order_acquire);
    uint32_t capacity_frames = reader->header->capacity_frames;

    if (now_nanos != 0 &&
        (heartbeat_nanos == 0 ||
         now_nanos < heartbeat_nanos ||
         now_nanos - heartbeat_nanos > MIXED_AUDIO_HEARTBEAT_STALE_NANOS)) {
        zero_frames(output_frames, requested_frames);
        return MIXED_AUDIO_SHM_READER_STALE_HEARTBEAT;
    }

    if (generation != reader->local_generation) {
        reader->local_generation = generation;
        reader->local_read_frame_index = write_frame_index;
        if (reader->can_write_header) {
            atomic_store_explicit(&reader->header->read_frame_index,
                                  reader->local_read_frame_index,
                                  memory_order_release);
        }
        zero_frames(output_frames, requested_frames);
        return MIXED_AUDIO_SHM_READER_GENERATION_CHANGED;
    }

    mixed_audio_shm_reader_status_t status = MIXED_AUDIO_SHM_READER_OK;
    if (write_frame_index > reader->local_read_frame_index + capacity_frames) {
        reader->local_read_frame_index = write_frame_index - capacity_frames;
        status = MIXED_AUDIO_SHM_READER_OVERRUN;
    }

    uint64_t available_frames = write_frame_index > reader->local_read_frame_index
                                    ? write_frame_index - reader->local_read_frame_index
                                    : 0;
    uint32_t copied_frames = requested_frames;
    if (available_frames < copied_frames) {
        copied_frames = (uint32_t)available_frames;
        if (status == MIXED_AUDIO_SHM_READER_OK) {
            status = MIXED_AUDIO_SHM_READER_UNDERRUN;
        }
    }

    const float *frames = mixed_audio_shm_const_frames(reader->header);
    for (uint32_t i = 0; i < copied_frames; i++) {
        uint64_t source_frame_index = reader->local_read_frame_index + i;
        uint32_t slot = (uint32_t)(source_frame_index % capacity_frames);
        const float *source = frames + ((size_t)slot * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT);
        float *destination = output_frames + ((size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT);
        destination[0] = source[0];
        destination[1] = source[1];
    }

    if (copied_frames < requested_frames) {
        zero_frames(output_frames + ((size_t)copied_frames * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT),
                    requested_frames - copied_frames);
    }

    reader->local_read_frame_index += copied_frames;
    if (reader->can_write_header) {
        atomic_store_explicit(&reader->header->read_frame_index,
                              reader->local_read_frame_index,
                              memory_order_release);
    }
    if (out_copied_frames != NULL) {
        *out_copied_frames = copied_frames;
    }
    return status;
}

const char *mixed_audio_shm_reader_status_string(mixed_audio_shm_reader_status_t status)
{
    switch (status) {
        case MIXED_AUDIO_SHM_READER_OK:
            return "ok";
        case MIXED_AUDIO_SHM_READER_MISSING:
            return "missing";
        case MIXED_AUDIO_SHM_READER_OPEN_FAILED:
            return "open_failed";
        case MIXED_AUDIO_SHM_READER_STAT_FAILED:
            return "stat_failed";
        case MIXED_AUDIO_SHM_READER_MAP_FAILED:
            return "map_failed";
        case MIXED_AUDIO_SHM_READER_INVALID_HEADER:
            return "invalid_header";
        case MIXED_AUDIO_SHM_READER_NOT_MAPPED:
            return "not_mapped";
        case MIXED_AUDIO_SHM_READER_UNDERRUN:
            return "underrun";
        case MIXED_AUDIO_SHM_READER_OVERRUN:
            return "overrun";
        case MIXED_AUDIO_SHM_READER_GENERATION_CHANGED:
            return "generation_changed";
        case MIXED_AUDIO_SHM_READER_STALE_HEARTBEAT:
            return "stale_heartbeat";
        default:
            return "unknown";
    }
}
