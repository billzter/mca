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

#include "MixedAudioSharedMemoryReader.h"

static const char *kTestShmName = "/mca.reader.test";

static void fail(const char *message)
{
    fprintf(stderr, "shared-memory reader test failed: %s\n", message);
    shm_unlink(kTestShmName);
    exit(1);
}

static void expect_status(mixed_audio_shm_reader_status_t actual,
                          mixed_audio_shm_reader_status_t expected,
                          const char *message)
{
    if (actual != expected) {
        fprintf(stderr,
                "shared-memory reader test failed: %s (got %d expected %d errno %d)\n",
                message,
                actual,
                expected,
                errno);
        shm_unlink(kTestShmName);
        exit(1);
    }
}

static void expect_float(float actual, float expected, const char *message)
{
    if (fabsf(actual - expected) > 0.0001f) {
        fprintf(stderr,
                "shared-memory reader test failed: %s (got %.6f expected %.6f)\n",
                message,
                actual,
                expected);
        shm_unlink(kTestShmName);
        exit(1);
    }
}

static mixed_audio_shm_header_t *create_mapping(uint32_t capacity_frames, size_t *out_byte_count)
{
    shm_unlink(kTestShmName);

    size_t byte_count = mixed_audio_shm_total_byte_count(capacity_frames);
    int fd = shm_open(kTestShmName, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0) {
        fail("shm_open create mapping");
    }
    if (ftruncate(fd, (off_t)byte_count) != 0) {
        close(fd);
        fail("ftruncate mapping");
    }

    void *mapping = mmap(NULL, byte_count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapping == MAP_FAILED) {
        fail("mmap mapping");
    }

    memset(mapping, 0, byte_count);
    mixed_audio_shm_header_t *header = (mixed_audio_shm_header_t *)mapping;
    header->magic = MIXED_AUDIO_SHM_MAGIC;
    header->version = MIXED_AUDIO_SHM_VERSION;
    header->sample_rate = MIXED_AUDIO_OUTPUT_SAMPLE_RATE;
    header->channel_count = MIXED_AUDIO_OUTPUT_CHANNEL_COUNT;
    header->capacity_frames = capacity_frames;
    header->target_shared_fill_frames = MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES;
    atomic_store(&header->generation, 1);
    atomic_store(&header->producer_heartbeat_nanos, 1000);

    *out_byte_count = byte_count;
    return header;
}

static void write_frame(mixed_audio_shm_header_t *header,
                        uint64_t frame_index,
                        float left,
                        float right)
{
    float *frames = mixed_audio_shm_frames(header);
    uint32_t slot = (uint32_t)(frame_index % header->capacity_frames);
    frames[(size_t)slot * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT] = left;
    frames[(size_t)slot * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT + 1] = right;
}

static void test_missing_mapping_reads_silence(void)
{
    mixed_audio_shm_reader_t reader;
    float output[4] = {1.0f, 1.0f, 1.0f, 1.0f};
    uint32_t copied_frames = 99;

    shm_unlink(kTestShmName);
    mixed_audio_shm_reader_init(&reader);

    mixed_audio_shm_reader_status_t status =
        mixed_audio_shm_reader_open(&reader, kTestShmName);
    expect_status(status, MIXED_AUDIO_SHM_READER_MISSING, "missing mapping open status");

    status = mixed_audio_shm_reader_read_at_time(&reader, output, 2, 1000, &copied_frames);
    expect_status(status, MIXED_AUDIO_SHM_READER_NOT_MAPPED, "missing mapping read status");
    if (copied_frames != 0) {
        fail("missing mapping copied frame count");
    }
    expect_float(output[0], 0.0f, "missing mapping left 0");
    expect_float(output[1], 0.0f, "missing mapping right 0");
    expect_float(output[2], 0.0f, "missing mapping left 1");
    expect_float(output[3], 0.0f, "missing mapping right 1");

    mixed_audio_shm_reader_close(&reader);
}

static void test_continuous_read_advances_index(void)
{
    size_t byte_count = 0;
    mixed_audio_shm_header_t *header = create_mapping(8, &byte_count);
    write_frame(header, 0, 0.10f, -0.10f);
    write_frame(header, 1, 0.20f, -0.20f);
    write_frame(header, 2, 0.30f, -0.30f);
    atomic_store(&header->write_frame_index, 3);

    mixed_audio_shm_reader_t reader;
    float output[6] = {0};
    uint32_t copied_frames = 0;
    mixed_audio_shm_reader_init(&reader);

    expect_status(mixed_audio_shm_reader_open(&reader, kTestShmName),
                  MIXED_AUDIO_SHM_READER_OK,
                  "continuous mapping open status");
    expect_status(mixed_audio_shm_reader_read_at_time(&reader, output, 3, 1000, &copied_frames),
                  MIXED_AUDIO_SHM_READER_OK,
                  "continuous read status");

    if (copied_frames != 3) {
        fail("continuous copied frame count");
    }
    expect_float(output[0], 0.10f, "continuous left 0");
    expect_float(output[1], -0.10f, "continuous right 0");
    expect_float(output[2], 0.20f, "continuous left 1");
    expect_float(output[3], -0.20f, "continuous right 1");
    expect_float(output[4], 0.30f, "continuous left 2");
    expect_float(output[5], -0.30f, "continuous right 2");
    if (atomic_load(&header->read_frame_index) != 3) {
        fail("continuous shared read index");
    }

    mixed_audio_shm_reader_close(&reader);
    munmap(header, byte_count);
    shm_unlink(kTestShmName);
}

static void test_partial_underrun_zero_fills_tail(void)
{
    size_t byte_count = 0;
    mixed_audio_shm_header_t *header = create_mapping(8, &byte_count);
    write_frame(header, 0, 0.25f, -0.25f);
    atomic_store(&header->write_frame_index, 1);

    mixed_audio_shm_reader_t reader;
    float output[6] = {9.0f, 9.0f, 9.0f, 9.0f, 9.0f, 9.0f};
    uint32_t copied_frames = 0;
    mixed_audio_shm_reader_init(&reader);

    expect_status(mixed_audio_shm_reader_open(&reader, kTestShmName),
                  MIXED_AUDIO_SHM_READER_OK,
                  "underrun mapping open status");
    expect_status(mixed_audio_shm_reader_read_at_time(&reader, output, 3, 1000, &copied_frames),
                  MIXED_AUDIO_SHM_READER_UNDERRUN,
                  "partial underrun status");

    if (copied_frames != 1) {
        fail("partial underrun copied frame count");
    }
    expect_float(output[0], 0.25f, "partial underrun copied left");
    expect_float(output[1], -0.25f, "partial underrun copied right");
    expect_float(output[2], 0.0f, "partial underrun zero left 1");
    expect_float(output[3], 0.0f, "partial underrun zero right 1");
    expect_float(output[4], 0.0f, "partial underrun zero left 2");
    expect_float(output[5], 0.0f, "partial underrun zero right 2");

    mixed_audio_shm_reader_close(&reader);
    munmap(header, byte_count);
    shm_unlink(kTestShmName);
}

static void test_ring_wrap_reads_oldest_available_frames(void)
{
    size_t byte_count = 0;
    mixed_audio_shm_header_t *header = create_mapping(4, &byte_count);
    for (uint64_t frame_index = 0; frame_index < 6; frame_index++) {
        float value = 0.10f * (float)(frame_index + 1);
        write_frame(header, frame_index, value, -value);
    }
    atomic_store(&header->write_frame_index, 6);

    mixed_audio_shm_reader_t reader;
    float output[8] = {0};
    uint32_t copied_frames = 0;
    mixed_audio_shm_reader_init(&reader);

    expect_status(mixed_audio_shm_reader_open(&reader, kTestShmName),
                  MIXED_AUDIO_SHM_READER_OK,
                  "ring wrap mapping open status");
    expect_status(mixed_audio_shm_reader_read_at_time(&reader, output, 4, 1000, &copied_frames),
                  MIXED_AUDIO_SHM_READER_OK,
                  "ring wrap read status");

    if (copied_frames != 4) {
        fail("ring wrap copied frame count");
    }
    for (uint32_t i = 0; i < 4; i++) {
        float expected = 0.10f * (float)(i + 3);
        expect_float(output[(size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT],
                     expected,
                     "ring wrap left");
        expect_float(output[(size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT + 1],
                     -expected,
                     "ring wrap right");
    }

    mixed_audio_shm_reader_close(&reader);
    munmap(header, byte_count);
    shm_unlink(kTestShmName);
}

static void test_generation_change_resyncs_to_silence(void)
{
    size_t byte_count = 0;
    mixed_audio_shm_header_t *header = create_mapping(8, &byte_count);
    write_frame(header, 0, 0.10f, -0.10f);
    write_frame(header, 1, 0.20f, -0.20f);
    atomic_store(&header->write_frame_index, 2);

    mixed_audio_shm_reader_t reader;
    float output[4] = {0};
    uint32_t copied_frames = 0;
    mixed_audio_shm_reader_init(&reader);

    expect_status(mixed_audio_shm_reader_open(&reader, kTestShmName),
                  MIXED_AUDIO_SHM_READER_OK,
                  "generation mapping open status");
    expect_status(mixed_audio_shm_reader_read_at_time(&reader, output, 2, 1000, &copied_frames),
                  MIXED_AUDIO_SHM_READER_OK,
                  "generation first read status");

    atomic_store(&header->generation, 2);
    write_frame(header, 2, 0.30f, -0.30f);
    atomic_store(&header->write_frame_index, 3);
    output[0] = output[1] = output[2] = output[3] = 9.0f;

    expect_status(mixed_audio_shm_reader_read_at_time(&reader, output, 2, 1000, &copied_frames),
                  MIXED_AUDIO_SHM_READER_GENERATION_CHANGED,
                  "generation change read status");
    if (copied_frames != 0) {
        fail("generation change copied frame count");
    }
    expect_float(output[0], 0.0f, "generation change zero left 0");
    expect_float(output[1], 0.0f, "generation change zero right 0");
    expect_float(output[2], 0.0f, "generation change zero left 1");
    expect_float(output[3], 0.0f, "generation change zero right 1");

    mixed_audio_shm_reader_close(&reader);
    munmap(header, byte_count);
    shm_unlink(kTestShmName);
}

static void test_stale_heartbeat_reads_silence(void)
{
    size_t byte_count = 0;
    mixed_audio_shm_header_t *header = create_mapping(8, &byte_count);
    write_frame(header, 0, 0.25f, -0.25f);
    write_frame(header, 1, 0.25f, -0.25f);
    atomic_store(&header->write_frame_index, 2);

    mixed_audio_shm_reader_t reader;
    float output[4] = {9.0f, 9.0f, 9.0f, 9.0f};
    uint32_t copied_frames = 99;
    mixed_audio_shm_reader_init(&reader);

    expect_status(mixed_audio_shm_reader_open(&reader, kTestShmName),
                  MIXED_AUDIO_SHM_READER_OK,
                  "stale mapping open status");
    expect_status(mixed_audio_shm_reader_read_at_time(&reader,
                                                      output,
                                                      2,
                                                      1000 + MIXED_AUDIO_HEARTBEAT_STALE_NANOS + 1,
                                                      &copied_frames),
                  MIXED_AUDIO_SHM_READER_STALE_HEARTBEAT,
                  "stale heartbeat status");
    if (copied_frames != 0) {
        fail("stale heartbeat copied frame count");
    }
    expect_float(output[0], 0.0f, "stale heartbeat zero left 0");
    expect_float(output[1], 0.0f, "stale heartbeat zero right 0");
    expect_float(output[2], 0.0f, "stale heartbeat zero left 1");
    expect_float(output[3], 0.0f, "stale heartbeat zero right 1");

    mixed_audio_shm_reader_close(&reader);
    munmap(header, byte_count);
    shm_unlink(kTestShmName);
}

static void test_reopen_after_mapping_recreated_reads_new_frames(void)
{
    size_t first_byte_count = 0;
    mixed_audio_shm_header_t *first_header = create_mapping(4, &first_byte_count);
    write_frame(first_header, 0, 0.10f, -0.10f);
    atomic_store(&first_header->write_frame_index, 1);

    mixed_audio_shm_reader_t reader;
    mixed_audio_shm_reader_init(&reader);
    expect_status(mixed_audio_shm_reader_open(&reader, kTestShmName),
                  MIXED_AUDIO_SHM_READER_OK,
                  "reopen first mapping open status");

    munmap(first_header, first_byte_count);
    shm_unlink(kTestShmName);

    size_t second_byte_count = 0;
    mixed_audio_shm_header_t *second_header = create_mapping(4, &second_byte_count);
    atomic_store(&second_header->generation, 2);
    write_frame(second_header, 0, 0.30f, -0.30f);
    write_frame(second_header, 1, 0.40f, -0.40f);
    atomic_store(&second_header->write_frame_index, 2);

    expect_status(mixed_audio_shm_reader_reopen_if_changed(&reader, kTestShmName),
                  MIXED_AUDIO_SHM_READER_OK,
                  "reopen remap status");

    float output[4] = {0};
    uint32_t copied_frames = 0;
    expect_status(mixed_audio_shm_reader_read_at_time(&reader, output, 2, 1000, &copied_frames),
                  MIXED_AUDIO_SHM_READER_OK,
                  "reopen read status");
    if (copied_frames != 2) {
        fail("reopen copied frame count");
    }
    expect_float(output[0], 0.30f, "reopen left 0");
    expect_float(output[1], -0.30f, "reopen right 0");
    expect_float(output[2], 0.40f, "reopen left 1");
    expect_float(output[3], -0.40f, "reopen right 1");

    mixed_audio_shm_reader_close(&reader);
    munmap(second_header, second_byte_count);
    shm_unlink(kTestShmName);
}

int main(void)
{
    test_missing_mapping_reads_silence();
    test_continuous_read_advances_index();
    test_partial_underrun_zero_fills_tail();
    test_ring_wrap_reads_oldest_available_frames();
    test_generation_change_resyncs_to_silence();
    test_stale_heartbeat_reads_silence();
    test_reopen_after_mapping_recreated_reads_new_frames();

    printf("shared-memory reader test passed\n");
    return 0;
}
