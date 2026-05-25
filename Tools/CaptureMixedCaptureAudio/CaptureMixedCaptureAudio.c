#include <AudioToolbox/AudioQueue.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "MixedAudioSharedMemory.h"

enum {
    kDefaultCaptureFrames = 4800,
    kDefaultTimeoutMs = 5000,
    kCaptureBufferFrames = 512,
    kCaptureBufferCount = 3
};

static const char *kDeviceUID = "com.minamiktr.mca.device.MixedCaptureAudio";

typedef enum expected_capture {
    EXPECT_MARKER = 0,
    EXPECT_SILENCE,
    EXPECT_NONZERO
} expected_capture_t;

typedef struct capture_state {
    pthread_mutex_t mutex;
    uint32_t target_frames;
    uint32_t captured_frames;
    float *samples;
    bool done;
    bool saw_bad_buffer;
} capture_state_t;

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

static bool cfstring_equals_cstring(CFStringRef value, const char *expected)
{
    char buffer[512];
    return value != NULL &&
           CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8) &&
           strcmp(buffer, expected) == 0;
}

static CFStringRef copy_string_property(AudioObjectID object_id,
                                        AudioObjectPropertySelector selector)
{
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    CFStringRef value = NULL;
    UInt32 data_size = sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(object_id, &address, 0, NULL, &data_size, &value);
    if (status != noErr) {
        return NULL;
    }
    return value;
}

static bool find_mixed_capture_device(AudioObjectID *out_device_id)
{
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    UInt32 data_size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
                                                     &address,
                                                     0,
                                                     NULL,
                                                     &data_size);
    if (status != noErr || data_size == 0) {
        print_osstatus("failed to get device list size", status);
        return false;
    }

    UInt32 device_count = data_size / sizeof(AudioObjectID);
    AudioObjectID *devices = (AudioObjectID *)calloc(device_count, sizeof(AudioObjectID));
    if (devices == NULL) {
        fprintf(stderr, "failed to allocate device list\n");
        return false;
    }

    status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                        &address,
                                        0,
                                        NULL,
                                        &data_size,
                                        devices);
    if (status != noErr) {
        print_osstatus("failed to get device list", status);
        free(devices);
        return false;
    }

    bool found = false;
    for (UInt32 i = 0; i < device_count; i++) {
        CFStringRef uid = copy_string_property(devices[i], kAudioDevicePropertyDeviceUID);
        if (cfstring_equals_cstring(uid, kDeviceUID)) {
            *out_device_id = devices[i];
            found = true;
        }
        if (uid != NULL) {
            CFRelease(uid);
        }
        if (found) {
            break;
        }
    }

    free(devices);
    return found;
}

static void capture_callback(void *in_user_data,
                             AudioQueueRef in_queue,
                             AudioQueueBufferRef in_buffer,
                             const AudioTimeStamp *in_start_time,
                             UInt32 in_number_packet_descriptions,
                             const AudioStreamPacketDescription *in_packet_descriptions)
{
    (void)in_start_time;
    (void)in_number_packet_descriptions;
    (void)in_packet_descriptions;

    capture_state_t *state = (capture_state_t *)in_user_data;
    uint32_t frame_count =
        in_buffer->mAudioDataByteSize / (MIXED_AUDIO_OUTPUT_CHANNEL_COUNT * sizeof(float));
    bool should_reenqueue = true;

    pthread_mutex_lock(&state->mutex);
    if (in_buffer->mAudioDataByteSize %
            (MIXED_AUDIO_OUTPUT_CHANNEL_COUNT * sizeof(float)) !=
        0) {
        state->saw_bad_buffer = true;
    }

    uint32_t remaining = state->target_frames - state->captured_frames;
    uint32_t frames_to_copy = frame_count < remaining ? frame_count : remaining;
    if (frames_to_copy > 0) {
        memcpy(state->samples +
                   ((size_t)state->captured_frames * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT),
               in_buffer->mAudioData,
               mixed_audio_shm_frame_byte_count(frames_to_copy));
        state->captured_frames += frames_to_copy;
    }

    if (state->captured_frames >= state->target_frames || state->saw_bad_buffer) {
        state->done = true;
        should_reenqueue = false;
    }
    pthread_mutex_unlock(&state->mutex);

    if (should_reenqueue) {
        AudioQueueEnqueueBuffer(in_queue, in_buffer, 0, NULL);
    }
}

static bool capture_done(capture_state_t *state)
{
    pthread_mutex_lock(&state->mutex);
    bool done = state->done;
    pthread_mutex_unlock(&state->mutex);
    return done;
}

static bool verify_marker_capture(const capture_state_t *state)
{
    uint32_t matching_frames = 0;
    float max_left_error = 0.0f;
    float max_right_error = 0.0f;

    for (uint32_t i = 0; i < state->captured_frames; i++) {
        float left = state->samples[(size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT];
        float right = state->samples[(size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT + 1];
        float left_error = fabsf(left - MIXED_AUDIO_PHASE2_MARKER_LEFT);
        float right_error = fabsf(right - MIXED_AUDIO_PHASE2_MARKER_RIGHT);
        if (left_error > max_left_error) {
            max_left_error = left_error;
        }
        if (right_error > max_right_error) {
            max_right_error = right_error;
        }
        if (left_error <= 0.01f && right_error <= 0.01f) {
            matching_frames++;
        }
    }

    double ratio = state->captured_frames == 0
                       ? 0.0
                       : (double)matching_frames / (double)state->captured_frames;
    printf("captured_frames=%u matching_marker_frames=%u ratio=%.3f max_left_error=%.6f max_right_error=%.6f\n",
           state->captured_frames,
           matching_frames,
           ratio,
           max_left_error,
           max_right_error);

    return state->captured_frames > 0 && ratio >= 0.90;
}

static bool verify_silence_capture(const capture_state_t *state)
{
    uint32_t silent_frames = 0;
    float max_abs_sample = 0.0f;

    for (uint32_t i = 0; i < state->captured_frames; i++) {
        float left = state->samples[(size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT];
        float right = state->samples[(size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT + 1];
        float left_abs = fabsf(left);
        float right_abs = fabsf(right);
        if (left_abs > max_abs_sample) {
            max_abs_sample = left_abs;
        }
        if (right_abs > max_abs_sample) {
            max_abs_sample = right_abs;
        }
        if (left_abs <= 0.0001f && right_abs <= 0.0001f) {
            silent_frames++;
        }
    }

    double ratio = state->captured_frames == 0
                       ? 0.0
                       : (double)silent_frames / (double)state->captured_frames;
    printf("captured_frames=%u silent_frames=%u ratio=%.3f max_abs_sample=%.6f\n",
           state->captured_frames,
           silent_frames,
           ratio,
           max_abs_sample);

    return state->captured_frames > 0 && ratio >= 0.99;
}

static bool verify_nonzero_capture(const capture_state_t *state)
{
    uint32_t nonzero_frames = 0;
    float max_abs_sample = 0.0f;

    for (uint32_t i = 0; i < state->captured_frames; i++) {
        float left = state->samples[(size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT];
        float right = state->samples[(size_t)i * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT + 1];
        float left_abs = fabsf(left);
        float right_abs = fabsf(right);
        if (left_abs > max_abs_sample) {
            max_abs_sample = left_abs;
        }
        if (right_abs > max_abs_sample) {
            max_abs_sample = right_abs;
        }
        if (left_abs > 0.0001f || right_abs > 0.0001f) {
            nonzero_frames++;
        }
    }

    double ratio = state->captured_frames == 0
                       ? 0.0
                       : (double)nonzero_frames / (double)state->captured_frames;
    printf("captured_frames=%u nonzero_frames=%u ratio=%.3f max_abs_sample=%.6f\n",
           state->captured_frames,
           nonzero_frames,
           ratio,
           max_abs_sample);

    return state->captured_frames > 0 && ratio >= 0.10 && max_abs_sample > 0.0001f;
}

static uint32_t parse_u32_arg(int argc, char **argv, const char *name, uint32_t default_value)
{
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], name) == 0) {
            char *end = NULL;
            unsigned long value = strtoul(argv[i + 1], &end, 10);
            if (end != argv[i + 1] && *end == '\0' && value <= UINT32_MAX) {
                return (uint32_t)value;
            }
        }
    }
    return default_value;
}

static expected_capture_t parse_expected_capture(int argc, char **argv)
{
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--expect") == 0) {
            if (strcmp(argv[i + 1], "silence") == 0) {
                return EXPECT_SILENCE;
            }
            if (strcmp(argv[i + 1], "marker") == 0) {
                return EXPECT_MARKER;
            }
            if (strcmp(argv[i + 1], "nonzero") == 0) {
                return EXPECT_NONZERO;
            }
        }
    }
    return EXPECT_MARKER;
}

static const char *expected_capture_name(expected_capture_t expected)
{
    switch (expected) {
        case EXPECT_SILENCE:
            return "silence";
        case EXPECT_NONZERO:
            return "nonzero";
        case EXPECT_MARKER:
        default:
            return "marker";
    }
}

int main(int argc, char **argv)
{
    uint32_t target_frames = parse_u32_arg(argc, argv, "--frames", kDefaultCaptureFrames);
    uint32_t timeout_ms = parse_u32_arg(argc, argv, "--timeout-ms", kDefaultTimeoutMs);
    expected_capture_t expected = parse_expected_capture(argc, argv);
    if (target_frames == 0) {
        fprintf(stderr, "--frames must be greater than zero\n");
        return 1;
    }

    AudioObjectID device_id = kAudioObjectUnknown;
    if (!find_mixed_capture_device(&device_id)) {
        fprintf(stderr,
                "Mixed Capture Audio device not found. Install the HAL driver and restart coreaudiod first.\n");
        return 1;
    }

    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = MIXED_AUDIO_OUTPUT_SAMPLE_RATE;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = MIXED_AUDIO_OUTPUT_CHANNEL_COUNT * sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = MIXED_AUDIO_OUTPUT_CHANNEL_COUNT * sizeof(float);
    format.mChannelsPerFrame = MIXED_AUDIO_OUTPUT_CHANNEL_COUNT;
    format.mBitsPerChannel = sizeof(float) * 8;

    capture_state_t state;
    memset(&state, 0, sizeof(state));
    pthread_mutex_init(&state.mutex, NULL);
    state.target_frames = target_frames;
    state.samples = (float *)calloc((size_t)target_frames * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT,
                                    sizeof(float));
    if (state.samples == NULL) {
        fprintf(stderr, "failed to allocate capture buffer\n");
        pthread_mutex_destroy(&state.mutex);
        return 1;
    }

    AudioQueueRef queue = NULL;
    OSStatus status = AudioQueueNewInput(&format,
                                         capture_callback,
                                         &state,
                                         NULL,
                                         NULL,
                                         0,
                                         &queue);
    if (status != noErr) {
        print_osstatus("AudioQueueNewInput failed", status);
        free(state.samples);
        pthread_mutex_destroy(&state.mutex);
        return 1;
    }

    CFStringRef device_uid = CFStringCreateWithCString(kCFAllocatorDefault,
                                                       kDeviceUID,
                                                       kCFStringEncodingUTF8);
    if (device_uid == NULL) {
        fprintf(stderr, "failed to create device UID string\n");
        AudioQueueDispose(queue, true);
        free(state.samples);
        pthread_mutex_destroy(&state.mutex);
        return 1;
    }

    status = AudioQueueSetProperty(queue,
                                   kAudioQueueProperty_CurrentDevice,
                                   &device_uid,
                                   sizeof(device_uid));
    CFRelease(device_uid);
    if (status != noErr) {
        print_osstatus("AudioQueueSetProperty(CurrentDevice) failed", status);
        AudioQueueDispose(queue, true);
        free(state.samples);
        pthread_mutex_destroy(&state.mutex);
        return 1;
    }

    UInt32 buffer_byte_count =
        kCaptureBufferFrames * MIXED_AUDIO_OUTPUT_CHANNEL_COUNT * sizeof(float);
    for (int i = 0; i < kCaptureBufferCount; i++) {
        AudioQueueBufferRef buffer = NULL;
        status = AudioQueueAllocateBuffer(queue, buffer_byte_count, &buffer);
        if (status != noErr) {
            print_osstatus("AudioQueueAllocateBuffer failed", status);
            AudioQueueDispose(queue, true);
            free(state.samples);
            pthread_mutex_destroy(&state.mutex);
            return 1;
        }
        status = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
        if (status != noErr) {
            print_osstatus("AudioQueueEnqueueBuffer failed", status);
            AudioQueueDispose(queue, true);
            free(state.samples);
            pthread_mutex_destroy(&state.mutex);
            return 1;
        }
    }

    status = AudioQueueStart(queue, NULL);
    if (status != noErr) {
        print_osstatus("AudioQueueStart failed", status);
        AudioQueueDispose(queue, true);
        free(state.samples);
        pthread_mutex_destroy(&state.mutex);
        return 1;
    }

    uint32_t waited_ms = 0;
    while (!capture_done(&state) && waited_ms < timeout_ms) {
        usleep(10000);
        waited_ms += 10;
    }

    AudioQueueStop(queue, true);
    AudioQueueDispose(queue, true);

    pthread_mutex_lock(&state.mutex);
    bool timed_out = !state.done;
    bool bad_buffer = state.saw_bad_buffer;
    pthread_mutex_unlock(&state.mutex);

    if (timed_out) {
        fprintf(stderr, "timed out after %u ms capturing from Mixed Capture Audio\n", timeout_ms);
        free(state.samples);
        pthread_mutex_destroy(&state.mutex);
        return 1;
    }
    if (bad_buffer) {
        fprintf(stderr, "capture returned a non-frame-aligned buffer\n");
        free(state.samples);
        pthread_mutex_destroy(&state.mutex);
        return 1;
    }

    bool ok = false;
    if (expected == EXPECT_SILENCE) {
        ok = verify_silence_capture(&state);
    } else if (expected == EXPECT_NONZERO) {
        ok = verify_nonzero_capture(&state);
    } else {
        ok = verify_marker_capture(&state);
    }
    free(state.samples);
    pthread_mutex_destroy(&state.mutex);
    if (!ok) {
        if (expected == EXPECT_SILENCE) {
            fprintf(stderr, "captured audio was not silent as expected\n");
        } else if (expected == EXPECT_NONZERO) {
            fprintf(stderr, "captured audio did not contain enough nonzero frames\n");
        } else {
            fprintf(stderr, "captured audio did not match the expected shared-memory marker\n");
            fprintf(stderr,
                    "If the capture was silent, restart the active shared-memory producer, then restart coreaudiod so the HAL reader can reopen /mca.mix.v1.\n");
        }
        return 1;
    }

    printf("Core Audio capture verifier passed (%s)\n", expected_capture_name(expected));
    return 0;
}
