#ifndef MIXED_AUDIO_ENGINE_H
#define MIXED_AUDIO_ENGINE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE 48000u
#define MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS 2u

typedef struct MixedAudioEngineConfig {
    uint32_t source_capacity_frames;
    uint32_t max_source_skew_frames;
    uint32_t max_drift_correction_per_mix;
    float system_gain;
    float mic_gain;
    uint32_t mic_compression_enabled;
    float mic_compression_threshold_db;
    float mic_compression_ratio;
    float mic_compression_attack_ms;
    float mic_compression_release_ms;
    float mic_compression_makeup_db;
    float mic_gate_threshold_db;
    float mic_gate_attenuation_db;
} MixedAudioEngineConfig;

typedef struct MixedAudioEngineHealth {
    uint64_t frames_mixed;
    uint64_t system_underrun_frames;
    uint64_t mic_underrun_frames;
    uint64_t clipped_samples;
    uint32_t system_queue_frames;
    uint32_t mic_queue_frames;
    int32_t source_frame_delta;
    uint32_t source_frame_delta_abs;
    uint64_t system_drift_drop_frames;
    uint64_t mic_drift_drop_frames;
    uint64_t callback_error_count;
    uint32_t shared_ring_fill_frames;
    int32_t shared_ring_fill_error_frames;
    uint32_t shared_ring_fill_error_abs_frames;
    uint64_t shared_ring_overrun_frames;
} MixedAudioEngineHealth;

typedef struct MixedAudioEngineHandle MixedAudioEngineHandle;
typedef struct MixedAudioSessionHandle MixedAudioSessionHandle;

typedef struct MixedAudioSessionConfig {
    MixedAudioEngineConfig engine;
    uint32_t shared_memory_capacity_frames;
    uint32_t max_write_frames;
} MixedAudioSessionConfig;

MixedAudioEngineHandle *mixed_audio_engine_create(MixedAudioEngineConfig config);
void mixed_audio_engine_destroy(MixedAudioEngineHandle *handle);

uint32_t mixed_audio_engine_push_system_interleaved_stereo(
    MixedAudioEngineHandle *handle,
    const float *samples,
    uint32_t frames);

uint32_t mixed_audio_engine_push_mic_mono(
    MixedAudioEngineHandle *handle,
    const float *samples,
    uint32_t frames);

uint32_t mixed_audio_engine_mix_available(
    MixedAudioEngineHandle *handle,
    float *output,
    uint32_t frames);

int32_t mixed_audio_engine_set_levels(
    MixedAudioEngineHandle *handle,
    float system_gain,
    float mic_gain);

int32_t mixed_audio_engine_get_health(
    const MixedAudioEngineHandle *handle,
    MixedAudioEngineHealth *out_health);

MixedAudioSessionHandle *mixed_audio_session_create(MixedAudioSessionConfig config);
void mixed_audio_session_destroy(MixedAudioSessionHandle *handle);

uint32_t mixed_audio_session_push_system_interleaved_stereo(
    MixedAudioSessionHandle *handle,
    const float *samples,
    uint32_t frames);

uint32_t mixed_audio_session_push_mic_mono(
    MixedAudioSessionHandle *handle,
    const float *samples,
    uint32_t frames);

uint32_t mixed_audio_session_mix_and_write(
    MixedAudioSessionHandle *handle,
    uint32_t frames);

int32_t mixed_audio_session_reset_sources(MixedAudioSessionHandle *handle);

int32_t mixed_audio_session_set_levels(
    MixedAudioSessionHandle *handle,
    float system_gain,
    float mic_gain);

int32_t mixed_audio_session_set_mic_compression_enabled(
    MixedAudioSessionHandle *handle,
    uint32_t enabled);

int32_t mixed_audio_session_copy_levels(
    MixedAudioSessionHandle *handle,
    float *out_system_peak,
    float *out_mic_peak);

int32_t mixed_audio_session_get_health(
    const MixedAudioSessionHandle *handle,
    MixedAudioEngineHealth *out_health);

#ifdef __cplusplus
}
#endif

#endif
