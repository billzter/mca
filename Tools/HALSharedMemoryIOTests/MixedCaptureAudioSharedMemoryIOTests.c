#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "MixedAudioSharedMemory.h"

enum {
    kMixedAudioObjectID_Device = 2,
    kMixedAudioObjectID_InputStream = 3,
    kTestFrameCount = 4,
    kTestCapacityFrames = 8
};

typedef void *(*MixedCaptureAudioCreateFn)(CFAllocatorRef allocator, CFUUIDRef requested_type_uuid);

static uint64_t now_nanos(void)
{
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS) {
        return 0;
    }
    uint64_t host_time = mach_absolute_time();
    return host_time * (uint64_t)timebase.numer / (uint64_t)timebase.denom;
}

static void fail(const char *message)
{
    fprintf(stderr, "HAL shared-memory IO test failed: %s\n", message);
    shm_unlink(MIXED_AUDIO_SHM_NAME);
    exit(1);
}

static void expect_status(OSStatus status, const char *message)
{
    if (status != noErr) {
        fprintf(stderr, "HAL shared-memory IO test failed: %s (%d)\n", message, (int)status);
        shm_unlink(MIXED_AUDIO_SHM_NAME);
        exit(1);
    }
}

static void expect_float(float actual, float expected, const char *message)
{
    if (fabsf(actual - expected) > 0.0001f) {
        fprintf(stderr,
                "HAL shared-memory IO test failed: %s (got %.6f expected %.6f)\n",
                message,
                actual,
                expected);
        shm_unlink(MIXED_AUDIO_SHM_NAME);
        exit(1);
    }
}

static mixed_audio_shm_header_t *create_test_mapping(size_t *out_byte_count)
{
    shm_unlink(MIXED_AUDIO_SHM_NAME);

    size_t byte_count = mixed_audio_shm_total_byte_count(kTestCapacityFrames);
    int fd = shm_open(MIXED_AUDIO_SHM_NAME, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0) {
        fprintf(stderr, "shm_open failed: errno=%d (%s)\n", errno, strerror(errno));
        fail("create shared memory");
    }
    if (ftruncate(fd, (off_t)byte_count) != 0) {
        close(fd);
        fail("size shared memory");
    }

    void *mapping = mmap(NULL, byte_count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapping == MAP_FAILED) {
        fail("map shared memory");
    }

    memset(mapping, 0, byte_count);
    mixed_audio_shm_header_t *header = (mixed_audio_shm_header_t *)mapping;
    header->magic = MIXED_AUDIO_SHM_MAGIC;
    header->version = MIXED_AUDIO_SHM_VERSION;
    header->sample_rate = MIXED_AUDIO_OUTPUT_SAMPLE_RATE;
    header->channel_count = MIXED_AUDIO_OUTPUT_CHANNEL_COUNT;
    header->capacity_frames = kTestCapacityFrames;
    header->target_shared_fill_frames = MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES;
    atomic_store(&header->generation, 1);
    atomic_store(&header->producer_heartbeat_nanos, now_nanos());

    float *frames = mixed_audio_shm_frames(header);
    for (uint32_t i = 0; i < kTestFrameCount; i++) {
        frames[(size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT] = 0.10f * (float)(i + 1);
        frames[(size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT + 1] = -0.10f * (float)(i + 1);
    }
    atomic_store(&header->write_frame_index, kTestFrameCount);

    *out_byte_count = byte_count;
    return header;
}

int main(void)
{
    size_t byte_count = 0;
    mixed_audio_shm_header_t *header = create_test_mapping(&byte_count);

    const char *driver_path = "Build/Debug/MixedCaptureAudio.driver/Contents/MacOS/MixedCaptureAudio";
    void *library = dlopen(driver_path, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        fail("load driver");
    }

    MixedCaptureAudioCreateFn create =
        (MixedCaptureAudioCreateFn)dlsym(library, "MixedCaptureAudio_Create");
    if (create == NULL) {
        fail("factory symbol not found");
    }

    void *created = create(kCFAllocatorDefault, kAudioServerPlugInDriverInterfaceUUID);
    if (created == NULL) {
        fail("factory returned NULL");
    }

    AudioServerPlugInDriverInterface **interface_ptr =
        (AudioServerPlugInDriverInterface **)created;
    AudioServerPlugInDriverInterface *driver = *interface_ptr;
    if (driver == NULL || driver->Initialize == NULL || driver->StartIO == NULL ||
        driver->DoIOOperation == NULL || driver->StopIO == NULL || driver->Release == NULL) {
        fail("required callback is NULL");
    }

    AudioServerPlugInDriverRef driver_ref = (AudioServerPlugInDriverRef)interface_ptr;
    AudioServerPlugInHostInterface host = {0};
    expect_status(driver->Initialize(driver_ref, &host), "initialize");
    expect_status(driver->StartIO(driver_ref, kMixedAudioObjectID_Device, 1), "start IO");

    float audio[kTestFrameCount * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT];
    for (size_t i = 0; i < sizeof(audio) / sizeof(audio[0]); i++) {
        audio[i] = 9.0f;
    }
    AudioServerPlugInIOCycleInfo cycle_info = {0};
    expect_status(driver->DoIOOperation(driver_ref,
                                        kMixedAudioObjectID_Device,
                                        kMixedAudioObjectID_InputStream,
                                        1,
                                        kAudioServerPlugInIOOperationReadInput,
                                        kTestFrameCount,
                                        &cycle_info,
                                        audio,
                                        NULL),
                  "read input");

    for (uint32_t i = 0; i < kTestFrameCount; i++) {
        float expected = 0.10f * (float)(i + 1);
        expect_float(audio[(size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT], expected, "left sample");
        expect_float(audio[(size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT + 1], -expected, "right sample");
    }
    if (atomic_load(&header->read_frame_index) != kTestFrameCount) {
        fail("shared read index advanced");
    }

    expect_status(driver->StopIO(driver_ref, kMixedAudioObjectID_Device, 1), "stop IO");
    driver->Release(driver_ref);
    dlclose(library);
    munmap(header, byte_count);
    shm_unlink(MIXED_AUDIO_SHM_NAME);

    printf("HAL shared-memory IO test passed\n");
    return 0;
}
