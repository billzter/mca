#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "MixedAudioSharedMemoryProbe.h"

static const char *kTestShmName = "/mca.probe.test";

static void fail(const char *message)
{
    fprintf(stderr, "shared-memory probe test failed: %s\n", message);
    shm_unlink(kTestShmName);
    exit(1);
}

static void expect_status(mixed_audio_shm_probe_status_t actual,
                          mixed_audio_shm_probe_status_t expected,
                          const char *message)
{
    if (actual != expected) {
        fprintf(stderr, "shared-memory probe test failed: %s (got %d expected %d errno %d)\n",
                message,
                actual,
                expected,
                errno);
        shm_unlink(kTestShmName);
        exit(1);
    }
}

static void create_valid_mapping(void)
{
    shm_unlink(kTestShmName);

    uint32_t capacity_frames = MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES * 2u;
    size_t byte_count = mixed_audio_shm_total_byte_count(capacity_frames);
    int fd = shm_open(kTestShmName, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0) {
        fail("shm_open create valid mapping");
    }
    if (ftruncate(fd, (off_t)byte_count) != 0) {
        close(fd);
        fail("ftruncate valid mapping");
    }

    void *mapping = mmap(NULL, byte_count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapping == MAP_FAILED) {
        fail("mmap valid mapping");
    }

    mixed_audio_shm_header_t *header = (mixed_audio_shm_header_t *)mapping;
    memset(mapping, 0, byte_count);
    header->magic = MIXED_AUDIO_SHM_MAGIC;
    header->version = MIXED_AUDIO_SHM_VERSION;
    header->sample_rate = MIXED_AUDIO_OUTPUT_SAMPLE_RATE;
    header->channel_count = MIXED_AUDIO_OUTPUT_CHANNEL_COUNT;
    header->capacity_frames = capacity_frames;
    header->target_shared_fill_frames = MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES;
    atomic_store(&header->generation, 1);
    atomic_store(&header->producer_heartbeat_nanos, 123456789);

    float *frames = mixed_audio_shm_frames(header);
    frames[0] = MIXED_AUDIO_PHASE2_MARKER_LEFT;
    frames[1] = MIXED_AUDIO_PHASE2_MARKER_RIGHT;
    atomic_store(&header->write_frame_index, 1);

    munmap(mapping, byte_count);
}

int main(void)
{
    shm_unlink(kTestShmName);

    mixed_audio_shm_probe_result_t result = mixed_audio_shm_probe(kTestShmName);
    expect_status(result.status, MIXED_AUDIO_SHM_PROBE_MISSING, "missing mapping");

    int fd = shm_open(kTestShmName, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0) {
        fail("shm_open create invalid mapping");
    }
    if (ftruncate(fd, (off_t)sizeof(mixed_audio_shm_header_t)) != 0) {
        close(fd);
        fail("ftruncate invalid mapping");
    }
    close(fd);

    result = mixed_audio_shm_probe(kTestShmName);
    expect_status(result.status, MIXED_AUDIO_SHM_PROBE_INVALID_HEADER, "invalid header");

    create_valid_mapping();
    result = mixed_audio_shm_probe(kTestShmName);
    expect_status(result.status, MIXED_AUDIO_SHM_PROBE_OK, "valid mapping");
    if (result.generation != 1 || result.write_frame_index != 1) {
        fail("valid mapping counters");
    }
    if (fabsf(result.marker_left - MIXED_AUDIO_PHASE2_MARKER_LEFT) > 0.0001f ||
        fabsf(result.marker_right - MIXED_AUDIO_PHASE2_MARKER_RIGHT) > 0.0001f) {
        fail("valid mapping marker");
    }

    shm_unlink(kTestShmName);
    printf("shared-memory probe test passed\n");
    return 0;
}
