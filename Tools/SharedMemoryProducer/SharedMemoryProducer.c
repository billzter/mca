#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "MixedAudioSharedMemory.h"

enum {
    kSyntheticBatchFrames = 480
};

static volatile sig_atomic_t gShouldStop = 0;

static void handle_signal(int signal_number)
{
    (void)signal_number;
    gShouldStop = 1;
}

static uint64_t now_nanos(void)
{
    static mach_timebase_info_data_t timebase = {0, 0};
    if (timebase.denom == 0 && mach_timebase_info(&timebase) != KERN_SUCCESS) {
        return 0;
    }
    uint64_t host_time = mach_absolute_time();
    return host_time * (uint64_t)timebase.numer / (uint64_t)timebase.denom;
}

static void write_synthetic_frames(mixed_audio_shm_header_t *header,
                                   uint64_t first_frame_index,
                                   uint32_t frame_count)
{
    float *frames = mixed_audio_shm_frames(header);
    for (uint32_t i = 0; i < frame_count; i++) {
        uint64_t frame_index = first_frame_index + i;
        uint32_t slot = (uint32_t)(frame_index % header->capacity_frames);
        float *frame = frames + ((size_t)slot * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT);
        frame[0] = MIXED_AUDIO_PHASE2_MARKER_LEFT;
        frame[1] = MIXED_AUDIO_PHASE2_MARKER_RIGHT;
    }
    atomic_store_explicit(&header->producer_heartbeat_nanos, now_nanos(), memory_order_release);
    atomic_store_explicit(&header->write_frame_index,
                          first_frame_index + frame_count,
                          memory_order_release);
}

int main(int argc, char **argv)
{
    bool run_once = false;
    bool freeze_heartbeat = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--once") == 0) {
            run_once = true;
        } else if (strcmp(argv[i], "--freeze-heartbeat") == 0) {
            freeze_heartbeat = true;
        }
    }
    uint32_t capacity_frames = MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES * 5u;
    size_t byte_count = mixed_audio_shm_total_byte_count(capacity_frames);

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    shm_unlink(MIXED_AUDIO_SHM_NAME);
    mode_t previous_umask = umask(0);
    int fd = shm_open(MIXED_AUDIO_SHM_NAME, O_CREAT | O_EXCL | O_RDWR, 0644);
    umask(previous_umask);
    if (fd < 0) {
        fprintf(stderr, "failed to create %s: errno=%d (%s)\n",
                MIXED_AUDIO_SHM_NAME,
                errno,
                strerror(errno));
        return 1;
    }

    if (ftruncate(fd, (off_t)byte_count) != 0) {
        fprintf(stderr, "failed to size %s: errno=%d (%s)\n",
                MIXED_AUDIO_SHM_NAME,
                errno,
                strerror(errno));
        close(fd);
        shm_unlink(MIXED_AUDIO_SHM_NAME);
        return 1;
    }

    void *mapping = mmap(NULL, byte_count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapping == MAP_FAILED) {
        fprintf(stderr, "failed to map %s: errno=%d (%s)\n",
                MIXED_AUDIO_SHM_NAME,
                errno,
                strerror(errno));
        shm_unlink(MIXED_AUDIO_SHM_NAME);
        return 1;
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
    write_synthetic_frames(header, 0, MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES);

    printf("created %s\n", MIXED_AUDIO_SHM_NAME);
    printf("header version=%u sample_rate=%u channels=%u capacity_frames=%u target_fill_frames=%u\n",
           header->version,
           header->sample_rate,
           header->channel_count,
           header->capacity_frames,
           header->target_shared_fill_frames);
    printf("marker left=%.2f right=%.2f\n",
           MIXED_AUDIO_PHASE2_MARKER_LEFT,
           MIXED_AUDIO_PHASE2_MARKER_RIGHT);
    if (freeze_heartbeat) {
        printf("heartbeat frozen; press Ctrl-C to stop\n");
    } else if (!run_once) {
        printf("continuous synthetic writes active; press Ctrl-C to stop\n");
    }
    fflush(stdout);

    uint64_t frame_index = MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES;
    while (!gShouldStop && !run_once) {
        if (!freeze_heartbeat) {
            write_synthetic_frames(header, frame_index, kSyntheticBatchFrames);
            frame_index += kSyntheticBatchFrames;
        }
        usleep(10000);
    }

    munmap(mapping, byte_count);
    shm_unlink(MIXED_AUDIO_SHM_NAME);
    printf("removed %s\n", MIXED_AUDIO_SHM_NAME);
    return 0;
}
