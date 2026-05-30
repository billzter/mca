#ifndef MIXED_AUDIO_SHARED_MEMORY_H
#define MIXED_AUDIO_SHARED_MEMORY_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#define MIXED_AUDIO_SHM_MAGIC 0x4D415544u
#define MIXED_AUDIO_ABI_VERSION 1u
#define MIXED_AUDIO_SHM_VERSION MIXED_AUDIO_ABI_VERSION
#define MIXED_AUDIO_OUTPUT_SAMPLE_RATE 48000u
#define MIXED_AUDIO_OUTPUT_CHANNEL_COUNT 2u
#define MIXED_AUDIO_TARGET_SHARED_FILL_MS 50u
#define MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES 2400u
#define MIXED_AUDIO_HEARTBEAT_STALE_MS 500u
#define MIXED_AUDIO_HEARTBEAT_STALE_NANOS 500000000ull
#define MIXED_AUDIO_PHASE2_MARKER_LEFT 0.25f
#define MIXED_AUDIO_PHASE2_MARKER_RIGHT -0.25f

#define MIXED_AUDIO_SHM_NAME "/mca.mix.v1"

typedef struct mixed_audio_shm_header {
    uint32_t magic;
    uint32_t version;
    uint32_t sample_rate;
    uint32_t channel_count;
    uint32_t capacity_frames;
    uint32_t target_shared_fill_frames;
    _Atomic uint64_t write_frame_index;
    _Atomic uint64_t read_frame_index;
    _Atomic uint64_t generation;
    _Atomic uint64_t producer_heartbeat_nanos;
    _Atomic uint64_t underrun_count;
    _Atomic uint64_t overrun_count;
    _Atomic uint64_t dropped_frame_count;
    _Atomic uint64_t clipped_frame_count;
} mixed_audio_shm_header_t;

_Static_assert(sizeof(mixed_audio_shm_header_t) == 88,
               "shared-memory header size changed; update Rust mirror and bump ABI version");
_Static_assert(_Alignof(mixed_audio_shm_header_t) == 8,
               "shared-memory header alignment changed; update Rust mirror and bump ABI version");
_Static_assert(offsetof(mixed_audio_shm_header_t, write_frame_index) == 24,
               "write_frame_index offset changed; update Rust mirror and bump ABI version");
_Static_assert(offsetof(mixed_audio_shm_header_t, generation) == 40,
               "generation offset changed; update Rust mirror and bump ABI version");
_Static_assert(offsetof(mixed_audio_shm_header_t, producer_heartbeat_nanos) == 48,
               "producer_heartbeat_nanos offset changed; update Rust mirror and bump ABI version");

static inline size_t mixed_audio_shm_frame_byte_count(uint32_t frame_count)
{
    return (size_t)frame_count * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT * sizeof(float);
}

static inline size_t mixed_audio_shm_total_byte_count(uint32_t capacity_frames)
{
    return sizeof(mixed_audio_shm_header_t) + mixed_audio_shm_frame_byte_count(capacity_frames);
}

static inline float *mixed_audio_shm_frames(mixed_audio_shm_header_t *header)
{
    return (float *)((uint8_t *)header + sizeof(mixed_audio_shm_header_t));
}

static inline const float *mixed_audio_shm_const_frames(const mixed_audio_shm_header_t *header)
{
    return (const float *)((const uint8_t *)header + sizeof(mixed_audio_shm_header_t));
}

#endif
