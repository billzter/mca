#import <AudioToolbox/AudioQueue.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "MixedAudioEngine.h"
#include "MixedAudioSharedMemory.h"

enum {
    kOutputSampleRate = 48000,
    kOutputChannels = 2,
    kDefaultCaptureSeconds = 10,
    kMaxCaptureSeconds = 3600,
    kMicBufferFrameCount = 512,
    kMicBufferCount = 3,
    kFrameHistogramSize = 4096,
    kRustSessionSharedMemoryCapacityFrames = 12000,
    kRustSessionMaxWriteFrames = 2400
};

typedef struct cadence_stats {
    UInt64 callback_count;
    UInt64 frame_count;
    UInt64 min_frames_per_callback;
    UInt64 max_frames_per_callback;
    UInt64 frame_histogram[kFrameHistogramSize];
    UInt64 overflow_histogram_count;
} cadence_stats_t;

typedef struct sample_buffer {
    pthread_mutex_t mutex;
    float *samples;
    UInt32 channels;
    UInt64 capacity_frames;
    UInt64 frame_count;
    UInt64 nonzero_sample_count;
    float max_abs_sample;
    bool truncated;
    bool bad_buffer;
} sample_buffer_t;

typedef struct capture_context {
    sample_buffer_t system_audio;
    sample_buffer_t microphone;
    AudioStreamBasicDescription tap_format;
    AudioStreamBasicDescription mic_requested_format;
    AudioStreamBasicDescription mic_actual_format;
    cadence_stats_t tap_cadence;
    cadence_stats_t mic_cadence;
    UInt64 tap_callback_count;
    UInt64 mic_callback_count;
    atomic_bool mic_stopping;
    bool rust_session_enabled;
    pthread_mutex_t rust_session_mutex;
    MixedAudioSessionHandle *rust_session;
    UInt64 rust_system_pushed_frames;
    UInt64 rust_mic_pushed_frames;
    UInt64 rust_mixed_frames;
    UInt64 rust_push_failure_count;
    UInt64 rust_mix_failure_count;
} capture_context_t;

typedef struct options {
    int seconds;
    const char *output_path;
    const char *cadence_report_path;
    bool self_test;
    bool cadence_report;
    bool output_path_set;
    bool rust_session_shm;
} options_t;

static NSString *dictionary_key(const char *key)
{
    return [NSString stringWithUTF8String:key];
}

static void print_osstatus(const char *message, OSStatus status)
{
    fprintf(stderr, "%s: %d", message, (int)status);
    uint32_t code = (uint32_t)status;
    char fourcc[5] = {
        (char)((code >> 24) & 0xff),
        (char)((code >> 16) & 0xff),
        (char)((code >> 8) & 0xff),
        (char)(code & 0xff),
        0
    };
    if (fourcc[0] >= 32 && fourcc[0] <= 126 &&
        fourcc[1] >= 32 && fourcc[1] <= 126 &&
        fourcc[2] >= 32 && fourcc[2] <= 126 &&
        fourcc[3] >= 32 && fourcc[3] <= 126) {
        fprintf(stderr, " ('%s')", fourcc);
    }
    fprintf(stderr, "\n");
}

static const char *format_id_string(AudioFormatID format_id, char out[5])
{
    out[0] = (char)((format_id >> 24) & 0xff);
    out[1] = (char)((format_id >> 16) & 0xff);
    out[2] = (char)((format_id >> 8) & 0xff);
    out[3] = (char)(format_id & 0xff);
    out[4] = 0;
    for (size_t i = 0; i < 4; i++) {
        if (out[i] < 32 || out[i] > 126) {
            strcpy(out, "????");
            break;
        }
    }
    return out;
}

static bool parse_options(int argc, const char *argv[], options_t *options)
{
    options->seconds = kDefaultCaptureSeconds;
    options->output_path = "TestArtifacts/stage4-mixed-proof.wav";
    options->cadence_report_path = NULL;
    options->self_test = false;
    options->cadence_report = false;
    options->output_path_set = false;
    options->rust_session_shm = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--seconds") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--seconds requires a value\n");
                return false;
            }
            char *end = NULL;
            long parsed = strtol(argv[i + 1], &end, 10);
            if (end == argv[i + 1] || *end != '\0' ||
                parsed <= 0 || parsed > kMaxCaptureSeconds) {
                fprintf(stderr, "--seconds must be between 1 and %d\n", kMaxCaptureSeconds);
                return false;
            }
            options->seconds = (int)parsed;
            i++;
        } else if (strcmp(argv[i], "--output") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--output requires a path\n");
                return false;
            }
            options->output_path = argv[i + 1];
            options->output_path_set = true;
            i++;
        } else if (strcmp(argv[i], "--self-test") == 0) {
            options->self_test = true;
        } else if (strcmp(argv[i], "--cadence-report") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--cadence-report requires a path\n");
                return false;
            }
            options->cadence_report = true;
            options->cadence_report_path = argv[i + 1];
            i++;
        } else if (strcmp(argv[i], "--rust-session-shm") == 0) {
            options->rust_session_shm = true;
        } else if (strcmp(argv[i], "--help") == 0) {
            printf("usage: MixedWavProof [--seconds N] [--output path] [--self-test] [--cadence-report path] [--rust-session-shm]\n");
            return false;
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return false;
        }
    }
    return true;
}

static void cadence_record(cadence_stats_t *stats, UInt64 frames)
{
    stats->callback_count++;
    stats->frame_count += frames;
    if (stats->min_frames_per_callback == 0 || frames < stats->min_frames_per_callback) {
        stats->min_frames_per_callback = frames;
    }
    if (frames > stats->max_frames_per_callback) {
        stats->max_frames_per_callback = frames;
    }
    if (frames < kFrameHistogramSize) {
        stats->frame_histogram[frames]++;
    } else {
        stats->overflow_histogram_count++;
    }
}

static UInt64 cadence_common_frames(const cadence_stats_t *stats, UInt64 *out_count)
{
    UInt64 common_frames = 0;
    UInt64 common_count = 0;
    for (UInt64 frames = 0; frames < kFrameHistogramSize; frames++) {
        if (stats->frame_histogram[frames] > common_count) {
            common_count = stats->frame_histogram[frames];
            common_frames = frames;
        }
    }
    *out_count = common_count;
    return common_frames;
}

static void print_format_line(FILE *file,
                              const char *prefix,
                              const AudioStreamBasicDescription *format)
{
    char format_id[5];
    fprintf(file,
            "%s sample_rate=%.1f channels=%u format_id=%s flags=0x%x bits=%u bytes_per_frame=%u interleaved=%s\n",
            prefix,
            format->mSampleRate,
            format->mChannelsPerFrame,
            format_id_string(format->mFormatID, format_id),
            (unsigned int)format->mFormatFlags,
            format->mBitsPerChannel,
            format->mBytesPerFrame,
            (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? "no" : "yes");
}

static void print_cadence_line(FILE *file,
                               const char *prefix,
                               const cadence_stats_t *stats,
                               UInt64 expected_frames)
{
    UInt64 common_count = 0;
    UInt64 common_frames = cadence_common_frames(stats, &common_count);
    int64_t expected_delta = (int64_t)stats->frame_count - (int64_t)expected_frames;
    fprintf(file,
            "%s callbacks=%llu frames=%llu expected_frames=%llu frame_delta=%lld min_frames_per_callback=%llu max_frames_per_callback=%llu common_frames_per_callback=%llu common_count=%llu overflow_histogram_count=%llu\n",
            prefix,
            stats->callback_count,
            stats->frame_count,
            expected_frames,
            expected_delta,
            stats->min_frames_per_callback,
            stats->max_frames_per_callback,
            common_frames,
            common_count,
            stats->overflow_histogram_count);
}

static bool write_cadence_report(const char *path,
                                 const capture_context_t *context,
                                 int seconds)
{
    UInt64 expected_frames = (UInt64)seconds * kOutputSampleRate;
    FILE *file = fopen(path, "w");
    if (file == NULL) {
        perror("fopen cadence report");
        return false;
    }

    fprintf(file, "stage4_cadence_report version=1\n");
    fprintf(file,
            "duration_seconds=%d expected_output_sample_rate=%d expected_frames=%llu\n",
            seconds,
            kOutputSampleRate,
            expected_frames);
    print_format_line(file, "tap_format", &context->tap_format);
    print_format_line(file, "mic_requested_format", &context->mic_requested_format);
    print_format_line(file, "mic_actual_format", &context->mic_actual_format);
    print_cadence_line(file, "system_cadence", &context->tap_cadence, expected_frames);
    print_cadence_line(file, "mic_cadence", &context->mic_cadence, expected_frames);
    int64_t source_frame_delta =
        (int64_t)context->tap_cadence.frame_count - (int64_t)context->mic_cadence.frame_count;
    fprintf(file, "source_frame_delta system_minus_mic=%lld\n", source_frame_delta);
    fprintf(file, "notes=Run once at 48kHz output-device format and once at 44.1kHz if supported by the output device.\n");

    if (fclose(file) != 0) {
        return false;
    }

    printf("cadence_report path=%s\n", path);
    print_format_line(stdout, "tap_format", &context->tap_format);
    print_format_line(stdout, "mic_requested_format", &context->mic_requested_format);
    print_format_line(stdout, "mic_actual_format", &context->mic_actual_format);
    print_cadence_line(stdout, "system_cadence", &context->tap_cadence, expected_frames);
    print_cadence_line(stdout, "mic_cadence", &context->mic_cadence, expected_frames);
    printf("source_frame_delta system_minus_mic=%lld\n", source_frame_delta);
    return true;
}

static bool sample_buffer_init(sample_buffer_t *buffer,
                               UInt32 channels,
                               UInt64 capacity_frames)
{
    memset(buffer, 0, sizeof(*buffer));
    buffer->channels = channels;
    buffer->capacity_frames = capacity_frames;
    pthread_mutex_init(&buffer->mutex, NULL);

    size_t sample_count = (size_t)capacity_frames * channels;
    buffer->samples = (float *)calloc(sample_count, sizeof(float));
    if (buffer->samples == NULL) {
        pthread_mutex_destroy(&buffer->mutex);
        return false;
    }
    return true;
}

static void sample_buffer_destroy(sample_buffer_t *buffer)
{
    free(buffer->samples);
    buffer->samples = NULL;
    pthread_mutex_destroy(&buffer->mutex);
}

static void sample_buffer_append_interleaved(sample_buffer_t *buffer,
                                             const float *samples,
                                             UInt64 frame_count,
                                             UInt32 channels)
{
    pthread_mutex_lock(&buffer->mutex);
    if (channels != buffer->channels || samples == NULL) {
        buffer->bad_buffer = true;
        pthread_mutex_unlock(&buffer->mutex);
        return;
    }

    UInt64 remaining = buffer->capacity_frames - buffer->frame_count;
    UInt64 frames_to_copy = frame_count < remaining ? frame_count : remaining;
    if (frames_to_copy < frame_count) {
        buffer->truncated = true;
    }

    size_t dst_offset = (size_t)buffer->frame_count * buffer->channels;
    size_t samples_to_copy = (size_t)frames_to_copy * buffer->channels;
    memcpy(buffer->samples + dst_offset, samples, samples_to_copy * sizeof(float));

    for (size_t i = 0; i < samples_to_copy; i++) {
        float abs_sample = fabsf(samples[i]);
        if (abs_sample > buffer->max_abs_sample) {
            buffer->max_abs_sample = abs_sample;
        }
        if (abs_sample > 0.0001f) {
            buffer->nonzero_sample_count++;
        }
    }

    buffer->frame_count += frames_to_copy;
    pthread_mutex_unlock(&buffer->mutex);
}

static void sample_buffer_snapshot(const sample_buffer_t *buffer,
                                   UInt64 *out_frame_count,
                                   UInt64 *out_nonzero_count,
                                   float *out_max_abs,
                                   bool *out_truncated,
                                   bool *out_bad_buffer)
{
    sample_buffer_t *mutable_buffer = (sample_buffer_t *)buffer;
    pthread_mutex_lock(&mutable_buffer->mutex);
    *out_frame_count = buffer->frame_count;
    *out_nonzero_count = buffer->nonzero_sample_count;
    *out_max_abs = buffer->max_abs_sample;
    *out_truncated = buffer->truncated;
    *out_bad_buffer = buffer->bad_buffer;
    pthread_mutex_unlock(&mutable_buffer->mutex);
}

static bool rust_session_create(capture_context_t *context)
{
    MixedAudioSessionConfig config;
    memset(&config, 0, sizeof(config));
    config.engine.source_capacity_frames = kRustSessionSharedMemoryCapacityFrames;
    config.engine.max_source_skew_frames = MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES;
    config.engine.max_drift_correction_per_mix = 8;
    config.engine.system_gain = 0.70f;
    config.engine.mic_gain = 0.70f;
    config.shared_memory_capacity_frames = kRustSessionSharedMemoryCapacityFrames;
    config.max_write_frames = kRustSessionMaxWriteFrames;

    context->rust_session = mixed_audio_session_create(config);
    if (context->rust_session == NULL) {
        fprintf(stderr, "mixed_audio_session_create failed\n");
        return false;
    }
    return true;
}

static void rust_session_destroy(capture_context_t *context)
{
    if (context->rust_session != NULL) {
        mixed_audio_session_destroy(context->rust_session);
        context->rust_session = NULL;
    }
}

static void rust_session_push_system_and_write(capture_context_t *context,
                                               const float *samples,
                                               UInt32 frames)
{
    if (!context->rust_session_enabled || context->rust_session == NULL ||
        samples == NULL || frames == 0) {
        return;
    }

    pthread_mutex_lock(&context->rust_session_mutex);
    UInt32 pushed =
        mixed_audio_session_push_system_interleaved_stereo(context->rust_session,
                                                           samples,
                                                           frames);
    if (pushed != frames) {
        context->rust_push_failure_count++;
    } else {
        context->rust_system_pushed_frames += pushed;
    }

    UInt32 mixed = mixed_audio_session_mix_and_write(context->rust_session, frames);
    if (mixed != frames) {
        context->rust_mix_failure_count++;
    } else {
        context->rust_mixed_frames += mixed;
    }
    pthread_mutex_unlock(&context->rust_session_mutex);
}

static void rust_session_push_mic(capture_context_t *context,
                                  const float *samples,
                                  UInt32 frames)
{
    if (!context->rust_session_enabled || context->rust_session == NULL ||
        samples == NULL || frames == 0) {
        return;
    }

    pthread_mutex_lock(&context->rust_session_mutex);
    UInt32 pushed = mixed_audio_session_push_mic_mono(context->rust_session, samples, frames);
    if (pushed != frames) {
        context->rust_push_failure_count++;
    } else {
        context->rust_mic_pushed_frames += pushed;
    }
    pthread_mutex_unlock(&context->rust_session_mutex);
}

static void rust_session_print_health(capture_context_t *context)
{
    if (!context->rust_session_enabled || context->rust_session == NULL) {
        return;
    }

    MixedAudioEngineHealth health;
    memset(&health, 0, sizeof(health));
    pthread_mutex_lock(&context->rust_session_mutex);
    int32_t status = mixed_audio_session_get_health(context->rust_session, &health);
    pthread_mutex_unlock(&context->rust_session_mutex);
    if (status != 0) {
        fprintf(stderr, "mixed_audio_session_get_health failed\n");
        return;
    }

    printf("rust_session system_pushed_frames=%llu mic_pushed_frames=%llu mixed_frames=%llu push_failures=%llu mix_failures=%llu frames_mixed=%llu system_underrun_frames=%llu mic_underrun_frames=%llu clipped_samples=%llu system_queue_frames=%u mic_queue_frames=%u source_frame_delta=%d source_frame_delta_abs=%u system_drift_drop_frames=%llu mic_drift_drop_frames=%llu callback_error_count=%llu\n",
           context->rust_system_pushed_frames,
           context->rust_mic_pushed_frames,
           context->rust_mixed_frames,
           context->rust_push_failure_count,
           context->rust_mix_failure_count,
           health.frames_mixed,
           health.system_underrun_frames,
           health.mic_underrun_frames,
           health.clipped_samples,
           health.system_queue_frames,
           health.mic_queue_frames,
           health.source_frame_delta,
           health.source_frame_delta_abs,
           health.system_drift_drop_frames,
           health.mic_drift_drop_frames,
           health.callback_error_count);
}

static float clamp_float(float value)
{
    if (value > 1.0f) {
        return 1.0f;
    }
    if (value < -1.0f) {
        return -1.0f;
    }
    return value;
}

static bool write_le16(FILE *file, uint16_t value)
{
    uint8_t bytes[2] = {
        (uint8_t)(value & 0xff),
        (uint8_t)((value >> 8) & 0xff)
    };
    return fwrite(bytes, 1, sizeof(bytes), file) == sizeof(bytes);
}

static bool write_le32(FILE *file, uint32_t value)
{
    uint8_t bytes[4] = {
        (uint8_t)(value & 0xff),
        (uint8_t)((value >> 8) & 0xff),
        (uint8_t)((value >> 16) & 0xff),
        (uint8_t)((value >> 24) & 0xff)
    };
    return fwrite(bytes, 1, sizeof(bytes), file) == sizeof(bytes);
}

static bool write_float32_wav(const char *path, const float *samples, UInt64 frame_count)
{
    UInt64 data_bytes_64 = frame_count * kOutputChannels * sizeof(float);
    if (data_bytes_64 > UINT32_MAX - 36) {
        fprintf(stderr, "WAV too large for simple RIFF writer\n");
        return false;
    }

    FILE *file = fopen(path, "wb");
    if (file == NULL) {
        perror("fopen output WAV");
        return false;
    }

    uint32_t data_bytes = (uint32_t)data_bytes_64;
    bool ok = true;
    ok = ok && fwrite("RIFF", 1, 4, file) == 4;
    ok = ok && write_le32(file, 36u + data_bytes);
    ok = ok && fwrite("WAVE", 1, 4, file) == 4;
    ok = ok && fwrite("fmt ", 1, 4, file) == 4;
    ok = ok && write_le32(file, 16);
    ok = ok && write_le16(file, 3);
    ok = ok && write_le16(file, kOutputChannels);
    ok = ok && write_le32(file, kOutputSampleRate);
    ok = ok && write_le32(file, kOutputSampleRate * kOutputChannels * (uint32_t)sizeof(float));
    ok = ok && write_le16(file, kOutputChannels * (uint16_t)sizeof(float));
    ok = ok && write_le16(file, 32);
    ok = ok && fwrite("data", 1, 4, file) == 4;
    ok = ok && write_le32(file, data_bytes);
    ok = ok && fwrite(samples, 1, data_bytes, file) == data_bytes;

    if (fclose(file) != 0) {
        ok = false;
    }
    if (!ok) {
        fprintf(stderr, "failed to write complete WAV file\n");
    }
    return ok;
}

static bool mix_to_stereo_wav(const char *path,
                              const sample_buffer_t *system_audio,
                              const sample_buffer_t *microphone,
                              UInt64 requested_frames)
{
    sample_buffer_t *mutable_system = (sample_buffer_t *)system_audio;
    sample_buffer_t *mutable_mic = (sample_buffer_t *)microphone;
    pthread_mutex_lock(&mutable_system->mutex);
    pthread_mutex_lock(&mutable_mic->mutex);

    UInt64 available_frames = system_audio->frame_count < microphone->frame_count
                                  ? system_audio->frame_count
                                  : microphone->frame_count;
    UInt64 frames_to_mix = requested_frames < available_frames ? requested_frames : available_frames;
    float *mixed = NULL;
    if (frames_to_mix > 0) {
        mixed = (float *)calloc((size_t)frames_to_mix * kOutputChannels, sizeof(float));
    }
    if (frames_to_mix == 0 || mixed == NULL) {
        pthread_mutex_unlock(&mutable_mic->mutex);
        pthread_mutex_unlock(&mutable_system->mutex);
        fprintf(stderr, "not enough captured frames to mix\n");
        free(mixed);
        return false;
    }

    for (UInt64 frame = 0; frame < frames_to_mix; frame++) {
        float system_left = system_audio->samples[(size_t)frame * kOutputChannels];
        float system_right = system_audio->samples[(size_t)frame * kOutputChannels + 1];
        float mic = microphone->samples[frame];
        mixed[(size_t)frame * kOutputChannels] = clamp_float((system_left * 0.70f) + (mic * 0.70f));
        mixed[(size_t)frame * kOutputChannels + 1] = clamp_float((system_right * 0.70f) + (mic * 0.70f));
    }

    pthread_mutex_unlock(&mutable_mic->mutex);
    pthread_mutex_unlock(&mutable_system->mutex);

    bool ok = write_float32_wav(path, mixed, frames_to_mix);
    printf("mixed_wav path=%s frames=%llu seconds=%.3f\n",
           path,
           frames_to_mix,
           (double)frames_to_mix / (double)kOutputSampleRate);
    free(mixed);
    return ok;
}

static AudioObjectID copy_current_process_object(void)
{
    pid_t pid = getpid();
    AudioObjectID process_object_id = kAudioObjectUnknown;
    UInt32 data_size = sizeof(process_object_id);
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyTranslatePIDToProcessObject,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                 &address,
                                                 sizeof(pid),
                                                 &pid,
                                                 &data_size,
                                                 &process_object_id);
    if (status != noErr) {
        return kAudioObjectUnknown;
    }
    return process_object_id;
}

static bool copy_first_stream_format(AudioObjectID device_id,
                                     AudioObjectPropertyScope scope,
                                     AudioStreamBasicDescription *out_format)
{
    AudioObjectPropertyAddress streams_address = {
        .mSelector = kAudioDevicePropertyStreams,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain
    };

    UInt32 data_size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device_id,
                                                     &streams_address,
                                                     0,
                                                     NULL,
                                                     &data_size);
    if (status != noErr || data_size < sizeof(AudioObjectID)) {
        return false;
    }

    UInt32 stream_count = data_size / sizeof(AudioObjectID);
    AudioObjectID *streams = (AudioObjectID *)calloc(stream_count, sizeof(AudioObjectID));
    if (streams == NULL) {
        return false;
    }

    status = AudioObjectGetPropertyData(device_id,
                                        &streams_address,
                                        0,
                                        NULL,
                                        &data_size,
                                        streams);
    if (status != noErr) {
        free(streams);
        return false;
    }

    AudioObjectPropertyAddress format_address = {
        .mSelector = kAudioStreamPropertyVirtualFormat,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    data_size = sizeof(*out_format);
    status = AudioObjectGetPropertyData(streams[0],
                                        &format_address,
                                        0,
                                        NULL,
                                        &data_size,
                                        out_format);
    free(streams);
    return status == noErr;
}

static bool copy_aggregate_input_format(AudioObjectID device_id,
                                        AudioStreamBasicDescription *out_format)
{
    if (copy_first_stream_format(device_id, kAudioObjectPropertyScopeInput, out_format)) {
        return true;
    }
    return copy_first_stream_format(device_id, kAudioObjectPropertyScopeOutput, out_format);
}

static bool set_aggregate_tap_list(AudioObjectID aggregate_id, NSString *tap_uid)
{
    NSArray *tap_list_object = @[ tap_uid ];
    CFArrayRef tap_list = (__bridge CFArrayRef)tap_list_object;
    UInt32 data_size = sizeof(tap_list);
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioAggregateDevicePropertyTapList,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectSetPropertyData(aggregate_id,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 data_size,
                                                 &tap_list);
    if (status != noErr) {
        print_osstatus("AudioObjectSetPropertyData(kAudioAggregateDevicePropertyTapList) failed",
                       status);
        return false;
    }
    return true;
}

static void tap_io_proc_append_interleaved(capture_context_t *context,
                                           const AudioBuffer *buffer)
{
    if (buffer->mData == NULL ||
        buffer->mNumberChannels != kOutputChannels ||
        buffer->mDataByteSize % (kOutputChannels * sizeof(float)) != 0) {
        pthread_mutex_lock(&context->system_audio.mutex);
        context->system_audio.bad_buffer = true;
        pthread_mutex_unlock(&context->system_audio.mutex);
        return;
    }

    UInt64 frames = buffer->mDataByteSize / (kOutputChannels * sizeof(float));
    sample_buffer_append_interleaved(&context->system_audio,
                                     (const float *)buffer->mData,
                                     frames,
                                     kOutputChannels);
    rust_session_push_system_and_write(context, (const float *)buffer->mData, (UInt32)frames);
}

static void tap_io_proc_append_noninterleaved(capture_context_t *context,
                                              const AudioBufferList *input_data)
{
    if (input_data->mNumberBuffers < kOutputChannels ||
        input_data->mBuffers[0].mDataByteSize != input_data->mBuffers[1].mDataByteSize ||
        input_data->mBuffers[0].mDataByteSize % sizeof(float) != 0) {
        pthread_mutex_lock(&context->system_audio.mutex);
        context->system_audio.bad_buffer = true;
        pthread_mutex_unlock(&context->system_audio.mutex);
        return;
    }

    UInt64 frames = input_data->mBuffers[0].mDataByteSize / sizeof(float);
    float *interleaved = (float *)malloc((size_t)frames * kOutputChannels * sizeof(float));
    if (interleaved == NULL) {
        pthread_mutex_lock(&context->system_audio.mutex);
        context->system_audio.bad_buffer = true;
        pthread_mutex_unlock(&context->system_audio.mutex);
        return;
    }

    const float *left = (const float *)input_data->mBuffers[0].mData;
    const float *right = (const float *)input_data->mBuffers[1].mData;
    for (UInt64 frame = 0; frame < frames; frame++) {
        interleaved[(size_t)frame * kOutputChannels] = left[frame];
        interleaved[(size_t)frame * kOutputChannels + 1] = right[frame];
    }
    sample_buffer_append_interleaved(&context->system_audio,
                                     interleaved,
                                     frames,
                                     kOutputChannels);
    rust_session_push_system_and_write(context, interleaved, (UInt32)frames);
    free(interleaved);
}

static OSStatus tap_io_proc(AudioObjectID in_device,
                            const AudioTimeStamp *in_now,
                            const AudioBufferList *in_input_data,
                            const AudioTimeStamp *in_input_time,
                            AudioBufferList *out_output_data,
                            const AudioTimeStamp *in_output_time,
                            void *in_client_data)
{
    (void)in_device;
    (void)in_now;
    (void)in_input_time;
    (void)out_output_data;
    (void)in_output_time;

    capture_context_t *context = (capture_context_t *)in_client_data;
    if (context == NULL || in_input_data == NULL) {
        return noErr;
    }

    context->tap_callback_count++;
    bool is_float32 = context->tap_format.mFormatID == kAudioFormatLinearPCM &&
                      (context->tap_format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
                      context->tap_format.mBitsPerChannel == 32;
    if (!is_float32) {
        pthread_mutex_lock(&context->system_audio.mutex);
        context->system_audio.bad_buffer = true;
        pthread_mutex_unlock(&context->system_audio.mutex);
        return noErr;
    }

    if ((context->tap_format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) {
        UInt64 callback_frames = in_input_data->mNumberBuffers >= kOutputChannels
                                     ? in_input_data->mBuffers[0].mDataByteSize / sizeof(float)
                                     : 0;
        cadence_record(&context->tap_cadence, callback_frames);
        tap_io_proc_append_noninterleaved(context, in_input_data);
    } else {
        UInt64 callback_frames = 0;
        for (UInt32 i = 0; i < in_input_data->mNumberBuffers; i++) {
            callback_frames +=
                in_input_data->mBuffers[i].mDataByteSize / (kOutputChannels * sizeof(float));
            tap_io_proc_append_interleaved(context, &in_input_data->mBuffers[i]);
        }
        cadence_record(&context->tap_cadence, callback_frames);
    }

    return noErr;
}

static void mic_callback(void *user_data,
                         AudioQueueRef queue,
                         AudioQueueBufferRef buffer,
                         const AudioTimeStamp *start_time,
                         UInt32 number_packet_descriptions,
                         const AudioStreamPacketDescription *packet_descriptions)
{
    (void)start_time;
    (void)number_packet_descriptions;
    (void)packet_descriptions;

    capture_context_t *context = (capture_context_t *)user_data;
    context->mic_callback_count++;

    if (buffer->mAudioDataByteSize % sizeof(float) != 0) {
        pthread_mutex_lock(&context->microphone.mutex);
        context->microphone.bad_buffer = true;
        pthread_mutex_unlock(&context->microphone.mutex);
    } else {
        UInt64 frames = buffer->mAudioDataByteSize / sizeof(float);
        cadence_record(&context->mic_cadence, frames);
        sample_buffer_append_interleaved(&context->microphone,
                                         (const float *)buffer->mAudioData,
                                         frames,
                                         1);
        rust_session_push_mic(context, (const float *)buffer->mAudioData, (UInt32)frames);
    }

    if (atomic_load(&context->mic_stopping)) {
        return;
    }

    OSStatus status = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    if (status != noErr) {
        print_osstatus("AudioQueueEnqueueBuffer(mic) failed", status);
    }
}

static bool start_microphone_queue(capture_context_t *context,
                                   AudioQueueRef *out_queue,
                                   AudioQueueBufferRef buffers[kMicBufferCount])
{
    memset(&context->mic_requested_format, 0, sizeof(context->mic_requested_format));
    context->mic_requested_format.mSampleRate = kOutputSampleRate;
    context->mic_requested_format.mFormatID = kAudioFormatLinearPCM;
    context->mic_requested_format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    context->mic_requested_format.mBytesPerPacket = sizeof(float);
    context->mic_requested_format.mFramesPerPacket = 1;
    context->mic_requested_format.mBytesPerFrame = sizeof(float);
    context->mic_requested_format.mChannelsPerFrame = 1;
    context->mic_requested_format.mBitsPerChannel = 32;

    OSStatus status = AudioQueueNewInput(&context->mic_requested_format,
                                         mic_callback,
                                         context,
                                         NULL,
                                         kCFRunLoopCommonModes,
                                         0,
                                         out_queue);
    if (status != noErr) {
        print_osstatus("AudioQueueNewInput(mic) failed", status);
        return false;
    }

    UInt32 actual_format_size = sizeof(context->mic_actual_format);
    status = AudioQueueGetProperty(*out_queue,
                                   kAudioQueueProperty_StreamDescription,
                                   &context->mic_actual_format,
                                   &actual_format_size);
    if (status != noErr) {
        print_osstatus("AudioQueueGetProperty(StreamDescription) failed", status);
        context->mic_actual_format = context->mic_requested_format;
    }

    UInt32 buffer_size = kMicBufferFrameCount * context->mic_requested_format.mBytesPerFrame;
    for (UInt32 i = 0; i < kMicBufferCount; i++) {
        status = AudioQueueAllocateBuffer(*out_queue, buffer_size, &buffers[i]);
        if (status != noErr) {
            print_osstatus("AudioQueueAllocateBuffer(mic) failed", status);
            return false;
        }
        status = AudioQueueEnqueueBuffer(*out_queue, buffers[i], 0, NULL);
        if (status != noErr) {
            print_osstatus("AudioQueueEnqueueBuffer(mic) failed", status);
            return false;
        }
    }

    status = AudioQueueStart(*out_queue, NULL);
    if (status != noErr) {
        print_osstatus("AudioQueueStart(mic) failed", status);
        return false;
    }
    return true;
}

static bool run_self_test(const char *output_path)
{
    UInt64 frames = kOutputSampleRate;
    sample_buffer_t system_audio;
    sample_buffer_t microphone;
    if (!sample_buffer_init(&system_audio, kOutputChannels, frames) ||
        !sample_buffer_init(&microphone, 1, frames)) {
        fprintf(stderr, "self-test buffer allocation failed\n");
        return false;
    }

    float *system_samples = (float *)calloc((size_t)frames * kOutputChannels, sizeof(float));
    float *mic_samples = (float *)calloc((size_t)frames, sizeof(float));
    if (system_samples == NULL || mic_samples == NULL) {
        fprintf(stderr, "self-test sample allocation failed\n");
        free(system_samples);
        free(mic_samples);
        sample_buffer_destroy(&system_audio);
        sample_buffer_destroy(&microphone);
        return false;
    }

    for (UInt64 frame = 0; frame < frames; frame++) {
        double phase = (2.0 * M_PI * 440.0 * (double)frame) / (double)kOutputSampleRate;
        system_samples[(size_t)frame * kOutputChannels] = (float)(sin(phase) * 0.20);
        system_samples[(size_t)frame * kOutputChannels + 1] = (float)(sin(phase) * -0.20);
        mic_samples[frame] = frame < frames / 2 ? 0.15f : -0.15f;
    }

    sample_buffer_append_interleaved(&system_audio, system_samples, frames, kOutputChannels);
    sample_buffer_append_interleaved(&microphone, mic_samples, frames, 1);
    bool ok = mix_to_stereo_wav(output_path, &system_audio, &microphone, frames);

    FILE *file = fopen(output_path, "rb");
    if (file == NULL) {
        perror("fopen self-test output");
        ok = false;
    } else {
        char header[12];
        if (fread(header, 1, sizeof(header), file) != sizeof(header) ||
            memcmp(header, "RIFF", 4) != 0 ||
            memcmp(header + 8, "WAVE", 4) != 0) {
            fprintf(stderr, "self-test WAV header validation failed\n");
            ok = false;
        }
        fclose(file);
    }

    free(system_samples);
    free(mic_samples);
    sample_buffer_destroy(&system_audio);
    sample_buffer_destroy(&microphone);
    if (ok) {
        printf("mixed WAV self-test passed\n");
    }
    return ok;
}

static bool run_live_capture(const options_t *options)
{
    UInt64 requested_frames = (UInt64)options->seconds * kOutputSampleRate;
    UInt64 capacity_frames = requested_frames + (2 * kOutputSampleRate);

    capture_context_t context;
    memset(&context, 0, sizeof(context));
    context.rust_session_enabled = options->rust_session_shm;
    if (!sample_buffer_init(&context.system_audio, kOutputChannels, capacity_frames) ||
        !sample_buffer_init(&context.microphone, 1, capacity_frames)) {
        fprintf(stderr, "failed to allocate capture buffers\n");
        return false;
    }
    pthread_mutex_init(&context.rust_session_mutex, NULL);

    AudioObjectID own_process_object = copy_current_process_object();
    NSArray<NSNumber *> *excluded_processes =
        own_process_object == kAudioObjectUnknown
            ? @[]
            : @[ [NSNumber numberWithUnsignedInt:own_process_object] ];

    NSUUID *tap_uuid = [NSUUID UUID];
    NSString *tap_uid = [tap_uuid UUIDString];
    CATapDescription *tap_description =
        [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:excluded_processes];
    tap_description.name = @"MixedCaptureAudio Stage4 Mixed WAV";
    tap_description.UUID = tap_uuid;
    tap_description.privateTap = YES;
    tap_description.muteBehavior = CATapUnmuted;

    AudioObjectID tap_id = kAudioObjectUnknown;
    OSStatus status = AudioHardwareCreateProcessTap(tap_description, &tap_id);
    if (status != noErr) {
        print_osstatus("AudioHardwareCreateProcessTap failed", status);
        pthread_mutex_destroy(&context.rust_session_mutex);
        sample_buffer_destroy(&context.system_audio);
        sample_buffer_destroy(&context.microphone);
        return false;
    }
    if (tap_id == kAudioObjectUnknown) {
        fprintf(stderr, "AudioHardwareCreateProcessTap returned kAudioObjectUnknown\n");
        pthread_mutex_destroy(&context.rust_session_mutex);
        sample_buffer_destroy(&context.system_audio);
        sample_buffer_destroy(&context.microphone);
        return false;
    }

    NSString *aggregate_uid =
        [NSString stringWithFormat:@"com.minamiktr.mca.stage4.mixed-wav.%@", tap_uid];
    NSDictionary *aggregate_description = @{
        dictionary_key(kAudioAggregateDeviceNameKey) : @"MixedCaptureAudio Stage4 Mixed WAV",
        dictionary_key(kAudioAggregateDeviceUIDKey) : aggregate_uid,
        dictionary_key(kAudioAggregateDeviceIsPrivateKey) : @1,
        dictionary_key(kAudioAggregateDeviceIsStackedKey) : @0,
        dictionary_key(kAudioAggregateDeviceTapAutoStartKey) : @0
    };

    AudioObjectID aggregate_id = kAudioObjectUnknown;
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate_description,
                                                &aggregate_id);
    if (status != noErr) {
        print_osstatus("AudioHardwareCreateAggregateDevice failed", status);
        (void)AudioHardwareDestroyProcessTap(tap_id);
        pthread_mutex_destroy(&context.rust_session_mutex);
        sample_buffer_destroy(&context.system_audio);
        sample_buffer_destroy(&context.microphone);
        return false;
    }

    if (!set_aggregate_tap_list(aggregate_id, tap_uid)) {
        (void)AudioHardwareDestroyAggregateDevice(aggregate_id);
        (void)AudioHardwareDestroyProcessTap(tap_id);
        pthread_mutex_destroy(&context.rust_session_mutex);
        sample_buffer_destroy(&context.system_audio);
        sample_buffer_destroy(&context.microphone);
        return false;
    }

    usleep(300000);
    if (!copy_aggregate_input_format(aggregate_id, &context.tap_format)) {
        fprintf(stderr, "failed to discover aggregate tap stream format\n");
        (void)AudioHardwareDestroyAggregateDevice(aggregate_id);
        (void)AudioHardwareDestroyProcessTap(tap_id);
        pthread_mutex_destroy(&context.rust_session_mutex);
        sample_buffer_destroy(&context.system_audio);
        sample_buffer_destroy(&context.microphone);
        return false;
    }

    AudioDeviceIOProcID io_proc_id = NULL;
    status = AudioDeviceCreateIOProcID(aggregate_id, tap_io_proc, &context, &io_proc_id);
    if (status != noErr) {
        print_osstatus("AudioDeviceCreateIOProcID failed", status);
        (void)AudioHardwareDestroyAggregateDevice(aggregate_id);
        (void)AudioHardwareDestroyProcessTap(tap_id);
        pthread_mutex_destroy(&context.rust_session_mutex);
        sample_buffer_destroy(&context.system_audio);
        sample_buffer_destroy(&context.microphone);
        return false;
    }

    AudioQueueRef mic_queue = NULL;
    AudioQueueBufferRef mic_buffers[kMicBufferCount] = { NULL, NULL, NULL };
    if (!start_microphone_queue(&context, &mic_queue, mic_buffers)) {
        (void)AudioDeviceDestroyIOProcID(aggregate_id, io_proc_id);
        (void)AudioHardwareDestroyAggregateDevice(aggregate_id);
        (void)AudioHardwareDestroyProcessTap(tap_id);
        pthread_mutex_destroy(&context.rust_session_mutex);
        sample_buffer_destroy(&context.system_audio);
        sample_buffer_destroy(&context.microphone);
        return false;
    }

    if (context.rust_session_enabled && !rust_session_create(&context)) {
        (void)AudioQueueDispose(mic_queue, true);
        (void)AudioDeviceDestroyIOProcID(aggregate_id, io_proc_id);
        (void)AudioHardwareDestroyAggregateDevice(aggregate_id);
        (void)AudioHardwareDestroyProcessTap(tap_id);
        pthread_mutex_destroy(&context.rust_session_mutex);
        sample_buffer_destroy(&context.system_audio);
        sample_buffer_destroy(&context.microphone);
        return false;
    }

    status = AudioDeviceStart(aggregate_id, io_proc_id);
    if (status != noErr) {
        print_osstatus("AudioDeviceStart(process tap aggregate) failed", status);
        rust_session_destroy(&context);
        (void)AudioQueueDispose(mic_queue, true);
        (void)AudioDeviceDestroyIOProcID(aggregate_id, io_proc_id);
        (void)AudioHardwareDestroyAggregateDevice(aggregate_id);
        (void)AudioHardwareDestroyProcessTap(tap_id);
        pthread_mutex_destroy(&context.rust_session_mutex);
        sample_buffer_destroy(&context.system_audio);
        sample_buffer_destroy(&context.microphone);
        return false;
    }

    char format_id[5];
    printf("created_process_tap id=%u uid=%s excluded_own_process=%s\n",
           tap_id,
           [tap_uid UTF8String],
           own_process_object == kAudioObjectUnknown ? "no" : "yes");
    printf("created_private_aggregate id=%u uid=%s seconds=%d\n",
           aggregate_id,
           [aggregate_uid UTF8String],
           options->seconds);
    printf("tap_format sample_rate=%.1f channels=%u format_id=%s flags=0x%x bits=%u bytes_per_frame=%u\n",
           context.tap_format.mSampleRate,
           context.tap_format.mChannelsPerFrame,
           format_id_string(context.tap_format.mFormatID, format_id),
           (unsigned int)context.tap_format.mFormatFlags,
           context.tap_format.mBitsPerChannel,
           context.tap_format.mBytesPerFrame);
    printf("play system audio and speak into the selected/default microphone now\n");
    if (context.rust_session_enabled) {
        printf("rust_session_shm active name=%s\n", MIXED_AUDIO_SHM_NAME);
    }

    sleep((unsigned int)options->seconds);

    atomic_store(&context.mic_stopping, true);
    (void)AudioDeviceStop(aggregate_id, io_proc_id);
    (void)AudioQueueStop(mic_queue, true);
    (void)AudioQueueDispose(mic_queue, true);
    (void)AudioDeviceDestroyIOProcID(aggregate_id, io_proc_id);
    (void)AudioHardwareDestroyAggregateDevice(aggregate_id);
    (void)AudioHardwareDestroyProcessTap(tap_id);

    UInt64 system_frames = 0;
    UInt64 system_nonzero = 0;
    float system_max = 0.0f;
    bool system_truncated = false;
    bool system_bad = false;
    sample_buffer_snapshot(&context.system_audio,
                           &system_frames,
                           &system_nonzero,
                           &system_max,
                           &system_truncated,
                           &system_bad);

    UInt64 mic_frames = 0;
    UInt64 mic_nonzero = 0;
    float mic_max = 0.0f;
    bool mic_truncated = false;
    bool mic_bad = false;
    sample_buffer_snapshot(&context.microphone,
                           &mic_frames,
                           &mic_nonzero,
                           &mic_max,
                           &mic_truncated,
                           &mic_bad);

    printf("system_capture callbacks=%llu frames=%llu nonzero_samples=%llu max_abs_sample=%.6f truncated=%s bad_buffer=%s\n",
           context.tap_callback_count,
           system_frames,
           system_nonzero,
           system_max,
           system_truncated ? "yes" : "no",
           system_bad ? "yes" : "no");
    printf("mic_capture callbacks=%llu frames=%llu nonzero_samples=%llu max_abs_sample=%.6f truncated=%s bad_buffer=%s\n",
           context.mic_callback_count,
           mic_frames,
           mic_nonzero,
           mic_max,
           mic_truncated ? "yes" : "no",
           mic_bad ? "yes" : "no");
    rust_session_print_health(&context);

    bool ok = true;
    if (system_bad || mic_bad) {
        fprintf(stderr, "one or more capture buffers had an unexpected shape\n");
        ok = false;
    }
    bool system_audible =
        system_frames >= kOutputSampleRate && system_nonzero > 0 && system_max > 0.0001f;
    bool mic_audible =
        mic_frames >= kOutputSampleRate && mic_nonzero > 0 && mic_max > 0.0001f;
    if (!system_audible && !context.rust_session_enabled) {
        fprintf(stderr, "system audio capture did not contain enough audible frames\n");
        ok = false;
    }
    if (!mic_audible && !context.rust_session_enabled) {
        fprintf(stderr, "microphone capture did not contain enough audible frames\n");
        ok = false;
    }
    if (context.rust_session_enabled) {
        if (!system_audible && !mic_audible) {
            fprintf(stderr, "Rust session proof did not capture any audible source\n");
            ok = false;
        }
        if (context.rust_push_failure_count != 0 || context.rust_mix_failure_count != 0) {
            fprintf(stderr, "Rust session reported push/mix failures\n");
            ok = false;
        }
        if (context.rust_mixed_frames < kOutputSampleRate) {
            fprintf(stderr, "Rust session did not mix enough frames\n");
            ok = false;
        }
    }
    if (ok && options->cadence_report) {
        ok = write_cadence_report(options->cadence_report_path, &context, options->seconds);
        if (ok && options->output_path_set) {
            ok = mix_to_stereo_wav(options->output_path,
                                   &context.system_audio,
                                   &context.microphone,
                                   requested_frames);
        }
    } else if (ok && context.rust_session_enabled && !options->output_path_set) {
        printf("rust_session_shm path=%s mixed_frames=%llu\n",
               MIXED_AUDIO_SHM_NAME,
               context.rust_mixed_frames);
    } else if (ok) {
        ok = mix_to_stereo_wav(options->output_path,
                               &context.system_audio,
                               &context.microphone,
                               requested_frames);
    }

    rust_session_destroy(&context);
    pthread_mutex_destroy(&context.rust_session_mutex);
    sample_buffer_destroy(&context.system_audio);
    sample_buffer_destroy(&context.microphone);
    if (ok) {
        if (context.rust_session_enabled) {
            printf("stage5 live Rust session proof passed\n");
        } else {
            printf(options->cadence_report ? "stage4 cadence proof passed\n"
                                           : "stage4 mixed WAV proof passed\n");
        }
    }
    return ok;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        setvbuf(stderr, NULL, _IOLBF, 0);

        options_t options;
        if (!parse_options(argc, argv, &options)) {
            return 2;
        }

        bool ok = options.self_test
                      ? run_self_test(options.output_path)
                      : run_live_capture(&options);
        return ok ? 0 : 1;
    }
}
