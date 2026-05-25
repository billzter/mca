#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
    kDefaultCaptureSeconds = 5,
    kMaxCaptureSeconds = 60
};

typedef struct tap_capture_state {
    pthread_mutex_t mutex;
    AudioStreamBasicDescription format;
    UInt32 bytes_per_sample;
    UInt64 callback_count;
    UInt64 frame_count;
    UInt64 nonzero_sample_count;
    float max_abs_sample;
    bool saw_bad_buffer;
} tap_capture_state_t;

typedef struct tap_capture_snapshot {
    AudioStreamBasicDescription format;
    UInt64 callback_count;
    UInt64 frame_count;
    UInt64 nonzero_sample_count;
    float max_abs_sample;
    bool saw_bad_buffer;
} tap_capture_snapshot_t;

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

static bool parse_seconds(int argc, const char *argv[], int *out_seconds)
{
    *out_seconds = kDefaultCaptureSeconds;
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
            *out_seconds = (int)parsed;
            i++;
        } else if (strcmp(argv[i], "--help") == 0) {
            printf("usage: ProcessTapProof [--seconds N]\n");
            return false;
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return false;
        }
    }
    return true;
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

static CFStringRef copy_tap_uid(AudioObjectID tap_id, OSStatus *out_status)
{
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioTapPropertyUID,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    CFStringRef uid = NULL;
    UInt32 data_size = sizeof(uid);
    OSStatus status = AudioObjectGetPropertyData(tap_id,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &data_size,
                                                 &uid);
    if (out_status != NULL) {
        *out_status = status;
    }
    if (status != noErr) {
        return NULL;
    }
    return uid;
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

static UInt32 frame_count_for_buffer(const AudioBuffer *buffer,
                                     const AudioStreamBasicDescription *format,
                                     UInt32 bytes_per_sample)
{
    if (buffer->mDataByteSize == 0) {
        return 0;
    }
    if (format->mBytesPerFrame > 0 && format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) {
        UInt32 channels = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
        UInt32 bytes_per_frame = channels * bytes_per_sample;
        return bytes_per_frame == 0 ? 0 : buffer->mDataByteSize / bytes_per_frame;
    }
    if (format->mBytesPerFrame > 0) {
        return buffer->mDataByteSize / format->mBytesPerFrame;
    }
    UInt32 channels = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
    UInt32 bytes_per_frame = channels * bytes_per_sample;
    return bytes_per_frame == 0 ? 0 : buffer->mDataByteSize / bytes_per_frame;
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

    tap_capture_state_t *state = (tap_capture_state_t *)in_client_data;
    if (state == NULL || in_input_data == NULL) {
        return noErr;
    }

    UInt64 frames = 0;
    UInt64 nonzero_samples = 0;
    float max_abs_sample = 0.0f;
    bool saw_bad_buffer = false;
    bool is_float32 = state->format.mFormatID == kAudioFormatLinearPCM &&
                      (state->format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
                      state->format.mBitsPerChannel == 32;

    for (UInt32 i = 0; i < in_input_data->mNumberBuffers; i++) {
        const AudioBuffer *buffer = &in_input_data->mBuffers[i];
        UInt32 buffer_frames = frame_count_for_buffer(buffer,
                                                      &state->format,
                                                      state->bytes_per_sample);
        frames += buffer_frames;

        if (!is_float32 || buffer->mData == NULL) {
            continue;
        }

        if (buffer->mDataByteSize % sizeof(float) != 0) {
            saw_bad_buffer = true;
            continue;
        }

        UInt32 sample_count = buffer->mDataByteSize / sizeof(float);
        const float *samples = (const float *)buffer->mData;
        for (UInt32 sample_index = 0; sample_index < sample_count; sample_index++) {
            float abs_sample = fabsf(samples[sample_index]);
            if (abs_sample > max_abs_sample) {
                max_abs_sample = abs_sample;
            }
            if (abs_sample > 0.0001f) {
                nonzero_samples++;
            }
        }
    }

    pthread_mutex_lock(&state->mutex);
    state->callback_count++;
    state->frame_count += frames;
    state->nonzero_sample_count += nonzero_samples;
    if (max_abs_sample > state->max_abs_sample) {
        state->max_abs_sample = max_abs_sample;
    }
    if (saw_bad_buffer) {
        state->saw_bad_buffer = true;
    }
    pthread_mutex_unlock(&state->mutex);

    return noErr;
}

static void print_capture_summary(const tap_capture_snapshot_t *snapshot)
{
    char format_id[5];
    printf("format sample_rate=%.1f channels=%u format_id=%s flags=0x%x bits=%u bytes_per_frame=%u\n",
           snapshot->format.mSampleRate,
           snapshot->format.mChannelsPerFrame,
           format_id_string(snapshot->format.mFormatID, format_id),
           (unsigned int)snapshot->format.mFormatFlags,
           snapshot->format.mBitsPerChannel,
           snapshot->format.mBytesPerFrame);
    printf("capture callbacks=%llu frames=%llu nonzero_samples=%llu max_abs_sample=%.6f bad_buffer=%s\n",
           snapshot->callback_count,
           snapshot->frame_count,
           snapshot->nonzero_sample_count,
           snapshot->max_abs_sample,
           snapshot->saw_bad_buffer ? "yes" : "no");
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        int seconds = 0;
        if (!parse_seconds(argc, argv, &seconds)) {
            return 2;
        }

        AudioObjectID own_process_object = copy_current_process_object();
        NSArray<NSNumber *> *excluded_processes =
            own_process_object == kAudioObjectUnknown
                ? @[]
                : @[ [NSNumber numberWithUnsignedInt:own_process_object] ];

        NSUUID *tap_uuid = [NSUUID UUID];
        NSString *tap_uid = [tap_uuid UUIDString];
        CATapDescription *tap_description =
            [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:excluded_processes];
        tap_description.name = @"MixedCaptureAudio Stage4 Process Tap";
        tap_description.UUID = tap_uuid;
        tap_description.privateTap = YES;
        tap_description.muteBehavior = CATapUnmuted;

        AudioObjectID tap_id = kAudioObjectUnknown;
        OSStatus status = AudioHardwareCreateProcessTap(tap_description, &tap_id);
        if (status != noErr) {
            print_osstatus("AudioHardwareCreateProcessTap failed", status);
            fprintf(stderr,
                    "This can indicate missing Screen & System Audio permission, unsupported macOS, or a Core Audio tap setup failure.\n");
            return 1;
        }
        if (tap_id == kAudioObjectUnknown) {
            fprintf(stderr, "AudioHardwareCreateProcessTap returned kAudioObjectUnknown\n");
            return 1;
        }

        OSStatus tap_uid_status = noErr;
        CFStringRef created_tap_uid_ref = copy_tap_uid(tap_id, &tap_uid_status);
        NSString *created_tap_uid = tap_uid;
        if (created_tap_uid_ref != NULL) {
            created_tap_uid = CFBridgingRelease(created_tap_uid_ref);
        } else {
            print_osstatus("warning: kAudioTapPropertyUID read failed; using requested tap UUID",
                           tap_uid_status);
        }
        NSString *aggregate_uid =
            [NSString stringWithFormat:@"com.minamiktr.mca.stage4.process-tap.%@", tap_uid];
        NSDictionary *aggregate_description = @{
            dictionary_key(kAudioAggregateDeviceNameKey) : @"MixedCaptureAudio Stage4 Process Tap",
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
            return 1;
        }

        if (!set_aggregate_tap_list(aggregate_id, created_tap_uid)) {
            (void)AudioHardwareDestroyAggregateDevice(aggregate_id);
            (void)AudioHardwareDestroyProcessTap(tap_id);
            return 1;
        }

        usleep(300000);

        tap_capture_state_t state;
        memset(&state, 0, sizeof(state));
        pthread_mutex_init(&state.mutex, NULL);
        if (!copy_aggregate_input_format(aggregate_id, &state.format)) {
            fprintf(stderr, "failed to discover aggregate tap stream format\n");
            (void)AudioHardwareDestroyAggregateDevice(aggregate_id);
            (void)AudioHardwareDestroyProcessTap(tap_id);
            pthread_mutex_destroy(&state.mutex);
            return 1;
        }
        state.bytes_per_sample = state.format.mBitsPerChannel / 8;

        AudioDeviceIOProcID io_proc_id = NULL;
        status = AudioDeviceCreateIOProcID(aggregate_id, tap_io_proc, &state, &io_proc_id);
        if (status != noErr) {
            print_osstatus("AudioDeviceCreateIOProcID failed", status);
            (void)AudioHardwareDestroyAggregateDevice(aggregate_id);
            (void)AudioHardwareDestroyProcessTap(tap_id);
            pthread_mutex_destroy(&state.mutex);
            return 1;
        }

        printf("created_process_tap id=%u uid=%s excluded_own_process=%s\n",
               tap_id,
               [created_tap_uid UTF8String],
               own_process_object == kAudioObjectUnknown ? "no" : "yes");
        printf("created_private_aggregate id=%u uid=%s seconds=%d\n",
               aggregate_id,
               [aggregate_uid UTF8String],
               seconds);
        printf("start Core Audio playback now if the capture reports zero frames or silence\n");

        status = AudioDeviceStart(aggregate_id, io_proc_id);
        if (status != noErr) {
            print_osstatus("AudioDeviceStart failed", status);
            (void)AudioDeviceDestroyIOProcID(aggregate_id, io_proc_id);
            (void)AudioHardwareDestroyAggregateDevice(aggregate_id);
            (void)AudioHardwareDestroyProcessTap(tap_id);
            pthread_mutex_destroy(&state.mutex);
            return 1;
        }

        sleep((unsigned int)seconds);

        status = AudioDeviceStop(aggregate_id, io_proc_id);
        if (status != noErr) {
            print_osstatus("AudioDeviceStop failed", status);
        }
        status = AudioDeviceDestroyIOProcID(aggregate_id, io_proc_id);
        if (status != noErr) {
            print_osstatus("AudioDeviceDestroyIOProcID failed", status);
        }

        tap_capture_snapshot_t snapshot;
        pthread_mutex_lock(&state.mutex);
        snapshot.format = state.format;
        snapshot.callback_count = state.callback_count;
        snapshot.frame_count = state.frame_count;
        snapshot.nonzero_sample_count = state.nonzero_sample_count;
        snapshot.max_abs_sample = state.max_abs_sample;
        snapshot.saw_bad_buffer = state.saw_bad_buffer;
        pthread_mutex_unlock(&state.mutex);

        status = AudioHardwareDestroyAggregateDevice(aggregate_id);
        if (status != noErr) {
            print_osstatus("AudioHardwareDestroyAggregateDevice failed", status);
        }
        status = AudioHardwareDestroyProcessTap(tap_id);
        if (status != noErr) {
            print_osstatus("AudioHardwareDestroyProcessTap failed", status);
        }

        print_capture_summary(&snapshot);
        pthread_mutex_destroy(&state.mutex);

        if (snapshot.saw_bad_buffer) {
            fprintf(stderr, "process tap produced an unexpected float buffer shape\n");
            return 1;
        }
        if (snapshot.callback_count == 0 || snapshot.frame_count == 0) {
            fprintf(stderr, "process tap produced no frames; play system audio and rerun the proof\n");
            return 1;
        }
        if (snapshot.nonzero_sample_count == 0 || snapshot.max_abs_sample <= 0.0001f) {
            fprintf(stderr, "process tap produced only silence; play audible system audio and rerun the proof\n");
            return 1;
        }

        printf("stage4 process tap proof passed\n");
        return 0;
    }
}
