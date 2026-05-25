#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const useconds_t kMCAAggregateTapSettleMicros = 300000;

typedef struct MCASystemAudioProbeResult {
    uint64_t callbackCount;
    uint64_t frameCount;
    uint64_t nonzeroSampleCount;
    float maxAbsSample;
    int32_t badBuffer;
    int32_t status;
} MCASystemAudioProbeResult;

typedef struct MCASystemAudioProbeState {
    pthread_mutex_t mutex;
    AudioStreamBasicDescription format;
    uint32_t bytesPerSample;
    MCASystemAudioProbeResult result;
    float nonzeroThreshold;
} MCASystemAudioProbeState;

static NSString *MCAStringKey(const char *key)
{
    return [NSString stringWithUTF8String:key];
}

static AudioObjectID MCACopyCurrentProcessObject(void)
{
    pid_t pid = getpid();
    AudioObjectID processObjectID = kAudioObjectUnknown;
    UInt32 dataSize = sizeof(processObjectID);
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyTranslatePIDToProcessObject,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                 &address,
                                                 sizeof(pid),
                                                 &pid,
                                                 &dataSize,
                                                 &processObjectID);
    if (status != noErr) {
        return kAudioObjectUnknown;
    }
    return processObjectID;
}

static CFStringRef MCACopyTapUID(AudioObjectID tapID)
{
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioTapPropertyUID,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    CFStringRef uid = NULL;
    UInt32 dataSize = sizeof(uid);
    OSStatus status = AudioObjectGetPropertyData(tapID, &address, 0, NULL, &dataSize, &uid);
    if (status != noErr) {
        return NULL;
    }
    return uid;
}

static bool MCACopyFirstStreamFormat(AudioObjectID deviceID,
                                     AudioObjectPropertyScope scope,
                                     AudioStreamBasicDescription *outFormat)
{
    AudioObjectPropertyAddress streamsAddress = {
        .mSelector = kAudioDevicePropertyStreams,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain
    };

    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(deviceID,
                                                     &streamsAddress,
                                                     0,
                                                     NULL,
                                                     &dataSize);
    if (status != noErr || dataSize < sizeof(AudioObjectID)) {
        return false;
    }

    UInt32 streamCount = dataSize / sizeof(AudioObjectID);
    AudioObjectID *streams = (AudioObjectID *)calloc(streamCount, sizeof(AudioObjectID));
    if (streams == NULL) {
        return false;
    }

    status = AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, NULL, &dataSize, streams);
    if (status != noErr) {
        free(streams);
        return false;
    }

    AudioObjectPropertyAddress formatAddress = {
        .mSelector = kAudioStreamPropertyVirtualFormat,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    dataSize = sizeof(*outFormat);
    status = AudioObjectGetPropertyData(streams[0], &formatAddress, 0, NULL, &dataSize, outFormat);
    free(streams);
    return status == noErr;
}

static bool MCACopyAggregateInputFormat(AudioObjectID deviceID,
                                        AudioStreamBasicDescription *outFormat)
{
    if (MCACopyFirstStreamFormat(deviceID, kAudioObjectPropertyScopeInput, outFormat)) {
        return true;
    }
    return MCACopyFirstStreamFormat(deviceID, kAudioObjectPropertyScopeOutput, outFormat);
}

static bool MCASetAggregateTapList(AudioObjectID aggregateID, NSString *tapUID)
{
    NSArray *tapListObject = @[ tapUID ];
    CFArrayRef tapList = (__bridge CFArrayRef)tapListObject;
    UInt32 dataSize = sizeof(tapList);
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioAggregateDevicePropertyTapList,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectSetPropertyData(aggregateID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 dataSize,
                                                 &tapList);
    return status == noErr;
}

static UInt32 MCAFrameCountForBuffer(const AudioBuffer *buffer,
                                     const AudioStreamBasicDescription *format,
                                     UInt32 bytesPerSample)
{
    if (buffer->mDataByteSize == 0) {
        return 0;
    }
    if (format->mBytesPerFrame > 0) {
        return buffer->mDataByteSize / format->mBytesPerFrame;
    }
    UInt32 channels = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
    UInt32 bytesPerFrame = channels * bytesPerSample;
    return bytesPerFrame == 0 ? 0 : buffer->mDataByteSize / bytesPerFrame;
}

static OSStatus MCATapIOProc(AudioObjectID inDevice,
                             const AudioTimeStamp *inNow,
                             const AudioBufferList *inInputData,
                             const AudioTimeStamp *inInputTime,
                             AudioBufferList *outOutputData,
                             const AudioTimeStamp *inOutputTime,
                             void *inClientData)
{
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)outOutputData;
    (void)inOutputTime;

    MCASystemAudioProbeState *state = (MCASystemAudioProbeState *)inClientData;
    if (state == NULL || inInputData == NULL) {
        return noErr;
    }

    uint64_t frames = 0;
    uint64_t nonzeroSamples = 0;
    float maxAbsSample = 0.0f;
    bool sawBadBuffer = false;
    bool isFloat32 = state->format.mFormatID == kAudioFormatLinearPCM &&
                     (state->format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
                     state->format.mBitsPerChannel == 32;

    for (UInt32 i = 0; i < inInputData->mNumberBuffers; i++) {
        const AudioBuffer *buffer = &inInputData->mBuffers[i];
        frames += MCAFrameCountForBuffer(buffer, &state->format, state->bytesPerSample);

        if (!isFloat32 || buffer->mData == NULL) {
            continue;
        }
        if (buffer->mDataByteSize % sizeof(float) != 0) {
            sawBadBuffer = true;
            continue;
        }

        UInt32 sampleCount = buffer->mDataByteSize / sizeof(float);
        const float *samples = (const float *)buffer->mData;
        for (UInt32 sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++) {
            float absSample = fabsf(samples[sampleIndex]);
            if (absSample > maxAbsSample) {
                maxAbsSample = absSample;
            }
            if (absSample > state->nonzeroThreshold) {
                nonzeroSamples++;
            }
        }
    }

    pthread_mutex_lock(&state->mutex);
    state->result.callbackCount++;
    state->result.frameCount += frames;
    state->result.nonzeroSampleCount += nonzeroSamples;
    if (maxAbsSample > state->result.maxAbsSample) {
        state->result.maxAbsSample = maxAbsSample;
    }
    if (sawBadBuffer) {
        state->result.badBuffer = 1;
    }
    pthread_mutex_unlock(&state->mutex);

    return noErr;
}

int32_t MCA_RunSystemAudioAccessProbe(double seconds,
                                      float nonzeroThreshold,
                                      MCASystemAudioProbeResult *outResult)
{
    if (outResult == NULL) {
        return -1;
    }
    memset(outResult, 0, sizeof(*outResult));

    @autoreleasepool {
        AudioObjectID ownProcessObject = MCACopyCurrentProcessObject();
        NSArray<NSNumber *> *excludedProcesses =
            ownProcessObject == kAudioObjectUnknown
                ? @[]
                : @[ [NSNumber numberWithUnsignedInt:ownProcessObject] ];

        NSUUID *tapUUID = [NSUUID UUID];
        NSString *tapUID = [tapUUID UUIDString];
        CATapDescription *tapDescription =
            [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:excludedProcesses];
        tapDescription.name = @"MixedCaptureAudio System Audio Test";
        tapDescription.UUID = tapUUID;
        tapDescription.privateTap = YES;
        tapDescription.muteBehavior = CATapUnmuted;

        AudioObjectID tapID = kAudioObjectUnknown;
        OSStatus status = AudioHardwareCreateProcessTap(tapDescription, &tapID);
        if (status != noErr || tapID == kAudioObjectUnknown) {
            outResult->status = (int32_t)status;
            return 0;
        }

        CFStringRef createdTapUIDRef = MCACopyTapUID(tapID);
        NSString *createdTapUID = tapUID;
        if (createdTapUIDRef != NULL) {
            createdTapUID = CFBridgingRelease(createdTapUIDRef);
        }

        NSString *aggregateUID =
            [NSString stringWithFormat:@"com.minamiktr.mca.system-audio-test.%@", tapUID];
        NSDictionary *aggregateDescription = @{
            MCAStringKey(kAudioAggregateDeviceNameKey) : @"MixedCaptureAudio System Audio Test",
            MCAStringKey(kAudioAggregateDeviceUIDKey) : aggregateUID,
            MCAStringKey(kAudioAggregateDeviceIsPrivateKey) : @1,
            MCAStringKey(kAudioAggregateDeviceIsStackedKey) : @0,
            MCAStringKey(kAudioAggregateDeviceTapAutoStartKey) : @0
        };

        AudioObjectID aggregateID = kAudioObjectUnknown;
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregateDescription,
                                                    &aggregateID);
        if (status != noErr || aggregateID == kAudioObjectUnknown) {
            outResult->status = (int32_t)status;
            (void)AudioHardwareDestroyProcessTap(tapID);
            return 0;
        }

        bool aggregateCreated = true;
        bool tapCreated = true;
        AudioDeviceIOProcID ioProcID = NULL;
        bool ioProcCreated = false;
        bool started = false;

        if (!MCASetAggregateTapList(aggregateID, createdTapUID)) {
            outResult->status = -2;
            goto cleanup;
        }

        usleep(kMCAAggregateTapSettleMicros);

        MCASystemAudioProbeState state;
        memset(&state, 0, sizeof(state));
        pthread_mutex_init(&state.mutex, NULL);
        state.nonzeroThreshold = nonzeroThreshold;

        if (!MCACopyAggregateInputFormat(aggregateID, &state.format)) {
            outResult->status = -3;
            pthread_mutex_destroy(&state.mutex);
            goto cleanup;
        }
        state.bytesPerSample = state.format.mBitsPerChannel / 8;

        status = AudioDeviceCreateIOProcID(aggregateID, MCATapIOProc, &state, &ioProcID);
        if (status != noErr) {
            outResult->status = (int32_t)status;
            pthread_mutex_destroy(&state.mutex);
            goto cleanup;
        }
        ioProcCreated = true;

        status = AudioDeviceStart(aggregateID, ioProcID);
        if (status != noErr) {
            outResult->status = (int32_t)status;
            pthread_mutex_destroy(&state.mutex);
            goto cleanup;
        }
        started = true;

        useconds_t captureMicros = (useconds_t)(seconds * 1000000.0);
        if (captureMicros < 500000) {
            captureMicros = 500000;
        }
        usleep(captureMicros);

        pthread_mutex_lock(&state.mutex);
        *outResult = state.result;
        pthread_mutex_unlock(&state.mutex);
        pthread_mutex_destroy(&state.mutex);

cleanup:
        if (started) {
            (void)AudioDeviceStop(aggregateID, ioProcID);
        }
        if (ioProcCreated) {
            (void)AudioDeviceDestroyIOProcID(aggregateID, ioProcID);
        }
        if (aggregateCreated) {
            (void)AudioHardwareDestroyAggregateDevice(aggregateID);
        }
        if (tapCreated) {
            (void)AudioHardwareDestroyProcessTap(tapID);
        }
        return 0;
    }
}
