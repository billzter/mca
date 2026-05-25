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

int32_t mixed_audio_session_get_health(
    const MixedAudioSessionHandle *handle,
    MixedAudioEngineHealth *out_health);

#ifdef __cplusplus
}
#endif

#endif
