#import <AudioToolbox/AudioQueue.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "MixedAudioEngine.h"
#include "MixedAudioSharedMemory.h"

static const useconds_t kMCAAggregateTapSettleMicros = 300000;

enum {
    kMCAOutputSampleRate = 48000,
    kMCAOutputChannels = 2,
    kMCAMicBufferFrameCount = 512,
    kMCAMicBufferCount = 3,
    kMCASharedMemoryCapacityFrames = 12000,
    kMCAMaxWriteFrames = 2400,
    kMCAMaxTapScratchFrames = 4096,
    kMCAProgramGraphFadeFrames = 480
};

typedef struct MCALiveMixerContext {
    pthread_mutex_t mutex;
    atomic_bool micStopping;
    bool running;
    AudioObjectID tapID;
    AudioObjectID aggregateID;
    AudioDeviceIOProcID ioProcID;
    AudioQueueRef micQueue;
    AudioQueueBufferRef micBuffers[kMCAMicBufferCount];
    AudioStreamBasicDescription tapFormat;
    AudioStreamBasicDescription micFormat;
    MixedAudioSessionHandle *session;
    UInt32 graphFadeInFramesRemaining;
    float tapScratch[kMCAMaxTapScratchFrames * kMCAOutputChannels];
} MCALiveMixerContext;

enum {
    kMCALiveMixerHealthFramesMixed = 0,
    kMCALiveMixerHealthSystemUnderrunFrames = 1,
    kMCALiveMixerHealthMicUnderrunFrames = 2,
    kMCALiveMixerHealthClippedSamples = 3,
    kMCALiveMixerHealthSystemQueueFrames = 4,
    kMCALiveMixerHealthMicQueueFrames = 5,
    kMCALiveMixerHealthSourceFrameDelta = 6,
    kMCALiveMixerHealthSourceFrameDeltaAbs = 7,
    kMCALiveMixerHealthSystemDriftDropFrames = 8,
    kMCALiveMixerHealthMicDriftDropFrames = 9,
    kMCALiveMixerHealthCallbackErrorCount = 10,
    kMCALiveMixerHealthCounterCount = 11
};

static uint64_t MCASignedInt32Bits(int32_t value)
{
    return (uint64_t)(int64_t)value;
}

static MCALiveMixerContext gMixer;
static pthread_once_t gMixerOnce = PTHREAD_ONCE_INIT;
static const char *kMCANoMicrophoneUID = "__MCA_NO_MIC__";

static void MCAInitMixer(void)
{
    memset(&gMixer, 0, sizeof(gMixer));
    pthread_mutex_init(&gMixer.mutex, NULL);
    gMixer.tapID = kAudioObjectUnknown;
    gMixer.aggregateID = kAudioObjectUnknown;
}

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
    return status == noErr ? processObjectID : kAudioObjectUnknown;
}

static CFStringRef MCACopyProcessBundleID(AudioObjectID processObjectID)
{
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioProcessPropertyBundleID,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    CFStringRef bundleID = NULL;
    UInt32 dataSize = sizeof(bundleID);
    OSStatus status = AudioObjectGetPropertyData(processObjectID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &dataSize,
                                                 &bundleID);
    return status == noErr ? bundleID : NULL;
}

static NSArray<NSString *> *MCAParseBundleIDList(const char *encodedBundleIDs)
{
    if (encodedBundleIDs == NULL || encodedBundleIDs[0] == '\0') {
        return @[];
    }

    NSString *encoded = [NSString stringWithUTF8String:encodedBundleIDs];
    if (encoded == nil) {
        return @[];
    }

    NSArray<NSString *> *parts = [encoded componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *part in parts) {
        NSString *bundleID = [part stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (bundleID.length == 0 || [result containsObject:bundleID]) {
            continue;
        }
        [result addObject:bundleID];
    }
    return result;
}

static NSArray<NSNumber *> *MCACopyProcessObjectIDsForBundleIDs(NSArray<NSString *> *bundleIDs,
                                                                AudioObjectID ownProcessObject)
{
    if (bundleIDs.count == 0) {
        return @[];
    }

    NSMutableSet<NSString *> *selectedBundleIDs = [NSMutableSet setWithArray:bundleIDs];
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyProcessObjectList,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
                                                     &address,
                                                     0,
                                                     NULL,
                                                     &dataSize);
    if (status != noErr || dataSize < sizeof(AudioObjectID)) {
        return @[];
    }

    UInt32 processCount = dataSize / sizeof(AudioObjectID);
    AudioObjectID *processes = (AudioObjectID *)calloc(processCount, sizeof(AudioObjectID));
    if (processes == NULL) {
        return @[];
    }

    status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                        &address,
                                        0,
                                        NULL,
                                        &dataSize,
                                        processes);
    if (status != noErr) {
        free(processes);
        return @[];
    }

    NSMutableArray<NSNumber *> *result = [NSMutableArray array];
    for (UInt32 i = 0; i < processCount; i++) {
        AudioObjectID processObject = processes[i];
        if (processObject == kAudioObjectUnknown || processObject == ownProcessObject) {
            continue;
        }

        CFStringRef bundleIDRef = MCACopyProcessBundleID(processObject);
        if (bundleIDRef == NULL) {
            continue;
        }
        NSString *bundleID = CFBridgingRelease(bundleIDRef);
        if ([selectedBundleIDs containsObject:bundleID]) {
            [result addObject:[NSNumber numberWithUnsignedInt:processObject]];
        }
    }

    free(processes);
    return result;
}

static void MCAApplySelectedAppRestoreHints(CATapDescription *tapDescription,
                                            NSArray<NSString *> *bundleIDs)
{
    if (tapDescription == nil || bundleIDs.count == 0) {
        return;
    }

#if defined(MAC_OS_VERSION_26_0)
    if (@available(macOS 26.0, *)) {
        tapDescription.bundleIDs = bundleIDs;
        tapDescription.processRestoreEnabled = YES;
    }
#else
    (void)bundleIDs;
#endif
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
    OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, NULL, &dataSize);
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
    OSStatus status = AudioObjectSetPropertyData(aggregateID, &address, 0, NULL, dataSize, &tapList);
    return status == noErr;
}

static bool MCACreateRustSession(MCALiveMixerContext *context)
{
    MixedAudioSessionConfig config;
    memset(&config, 0, sizeof(config));
    config.engine.source_capacity_frames = kMCASharedMemoryCapacityFrames;
    config.engine.max_source_skew_frames = MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES;
    config.engine.max_drift_correction_per_mix = 8;
    config.engine.system_gain = 0.70f;
    config.engine.mic_gain = 0.70f;
    config.shared_memory_capacity_frames = kMCASharedMemoryCapacityFrames;
    config.max_write_frames = kMCAMaxWriteFrames;

    context->session = mixed_audio_session_create(config);
    return context->session != NULL;
}

static bool MCAEnsureRustSession(MCALiveMixerContext *context)
{
    if (context->session != NULL) {
        return true;
    }
    return MCACreateRustSession(context);
}

static void MCAResetRustSources(MCALiveMixerContext *context)
{
    pthread_mutex_lock(&context->mutex);
    if (context->session != NULL) {
        (void)mixed_audio_session_reset_sources(context->session);
    }
    context->graphFadeInFramesRemaining = 0;
    pthread_mutex_unlock(&context->mutex);
}

static void MCAArmProgramGraphFadeIn(MCALiveMixerContext *context)
{
    pthread_mutex_lock(&context->mutex);
    context->graphFadeInFramesRemaining = kMCAProgramGraphFadeFrames;
    pthread_mutex_unlock(&context->mutex);
}

static void MCAApplyProgramGraphFadeInLocked(MCALiveMixerContext *context,
                                             float *samples,
                                             UInt32 frames)
{
    if (context->graphFadeInFramesRemaining == 0 || samples == NULL || frames == 0) {
        return;
    }

    UInt32 fadeFrames = context->graphFadeInFramesRemaining < frames
                            ? context->graphFadeInFramesRemaining
                            : frames;
    UInt32 fadeCompleted = kMCAProgramGraphFadeFrames - context->graphFadeInFramesRemaining;
    for (UInt32 frame = 0; frame < fadeFrames; frame++) {
        float gain = (float)(fadeCompleted + frame + 1) / (float)kMCAProgramGraphFadeFrames;
        samples[(size_t)frame * kMCAOutputChannels] *= gain;
        samples[(size_t)frame * kMCAOutputChannels + 1] *= gain;
    }
    context->graphFadeInFramesRemaining -= fadeFrames;
}

static void MCAWriteProgramGraphBridgeSilence(MCALiveMixerContext *context)
{
    if (context == NULL || context->session == NULL) {
        return;
    }

    float silence[kMCAProgramGraphFadeFrames * kMCAOutputChannels] = { 0 };
    pthread_mutex_lock(&context->mutex);
    if (context->running && context->session != NULL) {
        (void)mixed_audio_session_push_system_interleaved_stereo(context->session,
                                                                 silence,
                                                                 kMCAProgramGraphFadeFrames);
        (void)mixed_audio_session_mix_and_write(context->session, kMCAProgramGraphFadeFrames);
    }
    pthread_mutex_unlock(&context->mutex);
}

static void MCAPushSystemAndWrite(MCALiveMixerContext *context,
                                  const float *samples,
                                  UInt32 frames)
{
    if (context == NULL || context->session == NULL || samples == NULL || frames == 0) {
        return;
    }

    pthread_mutex_lock(&context->mutex);
    const float *samplesToPush = samples;
    if (context->graphFadeInFramesRemaining > 0) {
        if (frames <= kMCAMaxTapScratchFrames) {
            if (samples != context->tapScratch) {
                memcpy(context->tapScratch,
                       samples,
                       sizeof(float) * frames * kMCAOutputChannels);
            }
            MCAApplyProgramGraphFadeInLocked(context, context->tapScratch, frames);
            samplesToPush = context->tapScratch;
        } else {
            context->graphFadeInFramesRemaining = 0;
        }
    }
    (void)mixed_audio_session_push_system_interleaved_stereo(context->session,
                                                            samplesToPush,
                                                            frames);
    (void)mixed_audio_session_mix_and_write(context->session, frames);
    pthread_mutex_unlock(&context->mutex);
}

static void MCAPushMic(MCALiveMixerContext *context, const float *samples, UInt32 frames)
{
    if (context == NULL || context->session == NULL || samples == NULL || frames == 0) {
        return;
    }

    pthread_mutex_lock(&context->mutex);
    (void)mixed_audio_session_push_mic_mono(context->session, samples, frames);
    pthread_mutex_unlock(&context->mutex);
}

static void MCATapIOProcAppendInterleaved(MCALiveMixerContext *context,
                                          const AudioBuffer *buffer)
{
    if (buffer->mData == NULL ||
        buffer->mNumberChannels != kMCAOutputChannels ||
        buffer->mDataByteSize % (kMCAOutputChannels * sizeof(float)) != 0) {
        return;
    }

    UInt32 frames = buffer->mDataByteSize / (kMCAOutputChannels * sizeof(float));
    MCAPushSystemAndWrite(context, (const float *)buffer->mData, frames);
}

static void MCATapIOProcAppendNoninterleaved(MCALiveMixerContext *context,
                                             const AudioBufferList *inputData)
{
    if (inputData->mNumberBuffers < kMCAOutputChannels ||
        inputData->mBuffers[0].mDataByteSize != inputData->mBuffers[1].mDataByteSize ||
        inputData->mBuffers[0].mDataByteSize % sizeof(float) != 0) {
        return;
    }

    UInt32 frames = inputData->mBuffers[0].mDataByteSize / sizeof(float);
    if (frames > kMCAMaxTapScratchFrames) {
        return;
    }

    const float *left = (const float *)inputData->mBuffers[0].mData;
    const float *right = (const float *)inputData->mBuffers[1].mData;
    for (UInt32 frame = 0; frame < frames; frame++) {
        context->tapScratch[(size_t)frame * kMCAOutputChannels] = left[frame];
        context->tapScratch[(size_t)frame * kMCAOutputChannels + 1] = right[frame];
    }
    MCAPushSystemAndWrite(context, context->tapScratch, frames);
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

    MCALiveMixerContext *context = (MCALiveMixerContext *)inClientData;
    if (context == NULL || inInputData == NULL) {
        return noErr;
    }

    bool isFloat32 = context->tapFormat.mFormatID == kAudioFormatLinearPCM &&
                     (context->tapFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
                     context->tapFormat.mBitsPerChannel == 32;
    if (!isFloat32) {
        return noErr;
    }

    if ((context->tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) {
        MCATapIOProcAppendNoninterleaved(context, inInputData);
    } else {
        for (UInt32 i = 0; i < inInputData->mNumberBuffers; i++) {
            MCATapIOProcAppendInterleaved(context, &inInputData->mBuffers[i]);
        }
    }
    return noErr;
}

static void MCAMicCallback(void *userData,
                           AudioQueueRef queue,
                           AudioQueueBufferRef buffer,
                           const AudioTimeStamp *startTime,
                           UInt32 numberPacketDescriptions,
                           const AudioStreamPacketDescription *packetDescriptions)
{
    (void)startTime;
    (void)numberPacketDescriptions;
    (void)packetDescriptions;

    MCALiveMixerContext *context = (MCALiveMixerContext *)userData;
    if (context == NULL || buffer == NULL) {
        return;
    }

    if (buffer->mAudioData != NULL && buffer->mAudioDataByteSize % sizeof(float) == 0) {
        UInt32 frames = buffer->mAudioDataByteSize / sizeof(float);
        MCAPushMic(context, (const float *)buffer->mAudioData, frames);
    }

    if (atomic_load(&context->micStopping)) {
        return;
    }
    (void)AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

static bool MCAStartMicrophoneQueue(MCALiveMixerContext *context, const char *microphoneUID)
{
    memset(&context->micFormat, 0, sizeof(context->micFormat));
    context->micFormat.mSampleRate = kMCAOutputSampleRate;
    context->micFormat.mFormatID = kAudioFormatLinearPCM;
    context->micFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    context->micFormat.mBytesPerPacket = sizeof(float);
    context->micFormat.mFramesPerPacket = 1;
    context->micFormat.mBytesPerFrame = sizeof(float);
    context->micFormat.mChannelsPerFrame = 1;
    context->micFormat.mBitsPerChannel = 32;

    OSStatus status = AudioQueueNewInput(&context->micFormat,
                                         MCAMicCallback,
                                         context,
                                         NULL,
                                         kCFRunLoopCommonModes,
                                         0,
                                         &context->micQueue);
    if (status != noErr) {
        return false;
    }

    if (microphoneUID != NULL && microphoneUID[0] != '\0') {
        CFStringRef uid = CFStringCreateWithCString(kCFAllocatorDefault,
                                                    microphoneUID,
                                                    kCFStringEncodingUTF8);
        if (uid != NULL) {
            (void)AudioQueueSetProperty(context->micQueue,
                                        kAudioQueueProperty_CurrentDevice,
                                        &uid,
                                        sizeof(uid));
            CFRelease(uid);
        }
    }

    UInt32 bufferSize = kMCAMicBufferFrameCount * context->micFormat.mBytesPerFrame;
    for (UInt32 i = 0; i < kMCAMicBufferCount; i++) {
        status = AudioQueueAllocateBuffer(context->micQueue, bufferSize, &context->micBuffers[i]);
        if (status != noErr) {
            return false;
        }
        status = AudioQueueEnqueueBuffer(context->micQueue, context->micBuffers[i], 0, NULL);
        if (status != noErr) {
            return false;
        }
    }

    status = AudioQueueStart(context->micQueue, NULL);
    return status == noErr;
}

static void MCAStopSourceGraph(MCALiveMixerContext *context)
{
    MCAWriteProgramGraphBridgeSilence(context);
    atomic_store(&context->micStopping, true);
    if (context->aggregateID != kAudioObjectUnknown && context->ioProcID != NULL) {
        (void)AudioDeviceStop(context->aggregateID, context->ioProcID);
    }
    if (context->micQueue != NULL) {
        (void)AudioQueueStop(context->micQueue, true);
        (void)AudioQueueDispose(context->micQueue, true);
        context->micQueue = NULL;
    }
    if (context->aggregateID != kAudioObjectUnknown && context->ioProcID != NULL) {
        (void)AudioDeviceDestroyIOProcID(context->aggregateID, context->ioProcID);
        context->ioProcID = NULL;
    }
    if (context->aggregateID != kAudioObjectUnknown) {
        (void)AudioHardwareDestroyAggregateDevice(context->aggregateID);
        context->aggregateID = kAudioObjectUnknown;
    }
    if (context->tapID != kAudioObjectUnknown) {
        (void)AudioHardwareDestroyProcessTap(context->tapID);
        context->tapID = kAudioObjectUnknown;
    }
    pthread_mutex_lock(&context->mutex);
    memset(context->micBuffers, 0, sizeof(context->micBuffers));
    memset(&context->tapFormat, 0, sizeof(context->tapFormat));
    memset(&context->micFormat, 0, sizeof(context->micFormat));
    context->graphFadeInFramesRemaining = 0;
    context->running = false;
    pthread_mutex_unlock(&context->mutex);
}

static void MCADestroyRustSession(MCALiveMixerContext *context)
{
    pthread_mutex_lock(&context->mutex);
    if (context->session != NULL) {
        mixed_audio_session_destroy(context->session);
        context->session = NULL;
    }
    pthread_mutex_unlock(&context->mutex);
}

static void MCACleanup(MCALiveMixerContext *context)
{
    MCAStopSourceGraph(context);
    MCADestroyRustSession(context);
}

int32_t MCA_LiveMixerStart(const char *microphoneUID,
                           int32_t captureMode,
                           const char *selectedAppBundleIDs)
{
    pthread_once(&gMixerOnce, MCAInitMixer);

    MCAStopSourceGraph(&gMixer);
    if (!MCAEnsureRustSession(&gMixer)) {
        return -6;
    }
    MCAResetRustSources(&gMixer);

    atomic_store(&gMixer.micStopping, false);

    @autoreleasepool {
        AudioObjectID ownProcessObject = MCACopyCurrentProcessObject();
        NSArray<NSNumber *> *excludedProcesses =
            ownProcessObject == kAudioObjectUnknown
                ? @[]
                : @[ [NSNumber numberWithUnsignedInt:ownProcessObject] ];

        NSUUID *tapUUID = [NSUUID UUID];
        NSString *tapUID = [tapUUID UUIDString];
        CATapDescription *tapDescription = nil;
        if (captureMode == 1) {
            NSArray<NSString *> *bundleIDs = MCAParseBundleIDList(selectedAppBundleIDs);
            NSArray<NSNumber *> *includedProcesses =
                MCACopyProcessObjectIDsForBundleIDs(bundleIDs, ownProcessObject);
            tapDescription = [[CATapDescription alloc] initStereoMixdownOfProcesses:includedProcesses];
            MCAApplySelectedAppRestoreHints(tapDescription, bundleIDs);
        } else {
            tapDescription =
                [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:excludedProcesses];
        }
        tapDescription.name = @"MixedCaptureAudio Live Mixer";
        tapDescription.UUID = tapUUID;
        tapDescription.privateTap = YES;
        tapDescription.muteBehavior = CATapUnmuted;

        OSStatus status = AudioHardwareCreateProcessTap(tapDescription, &gMixer.tapID);
        if (status != noErr || gMixer.tapID == kAudioObjectUnknown) {
            MCAStopSourceGraph(&gMixer);
            return -1;
        }

        NSString *aggregateUID =
            [NSString stringWithFormat:@"com.minamiktr.mca.live-mixer.%@", tapUID];
        NSDictionary *aggregateDescription = @{
            MCAStringKey(kAudioAggregateDeviceNameKey) : @"MixedCaptureAudio Live Mixer",
            MCAStringKey(kAudioAggregateDeviceUIDKey) : aggregateUID,
            MCAStringKey(kAudioAggregateDeviceIsPrivateKey) : @1,
            MCAStringKey(kAudioAggregateDeviceIsStackedKey) : @0,
            MCAStringKey(kAudioAggregateDeviceTapAutoStartKey) : @0
        };

        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregateDescription,
                                                    &gMixer.aggregateID);
        if (status != noErr || gMixer.aggregateID == kAudioObjectUnknown) {
            MCAStopSourceGraph(&gMixer);
            return -2;
        }

        if (!MCASetAggregateTapList(gMixer.aggregateID, tapUID)) {
            MCAStopSourceGraph(&gMixer);
            return -3;
        }

        usleep(kMCAAggregateTapSettleMicros);
        if (!MCACopyAggregateInputFormat(gMixer.aggregateID, &gMixer.tapFormat)) {
            MCAStopSourceGraph(&gMixer);
            return -4;
        }

        status = AudioDeviceCreateIOProcID(gMixer.aggregateID,
                                           MCATapIOProc,
                                           &gMixer,
                                           &gMixer.ioProcID);
        if (status != noErr) {
            MCAStopSourceGraph(&gMixer);
            return -5;
        }

        bool shouldStartMicrophone =
            microphoneUID == NULL || strcmp(microphoneUID, kMCANoMicrophoneUID) != 0;
        if (shouldStartMicrophone) {
            if (!MCAStartMicrophoneQueue(&gMixer, microphoneUID)) {
                MCAStopSourceGraph(&gMixer);
                return -7;
            }
        }

        MCAArmProgramGraphFadeIn(&gMixer);
        status = AudioDeviceStart(gMixer.aggregateID, gMixer.ioProcID);
        if (status != noErr) {
            MCAStopSourceGraph(&gMixer);
            return -8;
        }

        pthread_mutex_lock(&gMixer.mutex);
        gMixer.running = true;
        pthread_mutex_unlock(&gMixer.mutex);
        return 0;
    }
}

void MCA_LiveMixerStop(void)
{
    pthread_once(&gMixerOnce, MCAInitMixer);
    MCACleanup(&gMixer);
}

int32_t MCA_LiveMixerSupportsSelectedAppProcessRestore(void)
{
#if defined(MAC_OS_VERSION_26_0)
    if (@available(macOS 26.0, *)) {
        return 1;
    }
#endif
    return 0;
}

int32_t MCA_LiveMixerCopyHealthCounters(uint64_t *outCounters, uint32_t counterCount)
{
    if (outCounters == NULL) {
        return -1;
    }
    if (counterCount < kMCALiveMixerHealthCounterCount) {
        return -2;
    }

    pthread_once(&gMixerOnce, MCAInitMixer);
    memset(outCounters, 0, sizeof(uint64_t) * counterCount);

    pthread_mutex_lock(&gMixer.mutex);
    if (gMixer.session == NULL) {
        pthread_mutex_unlock(&gMixer.mutex);
        return -3;
    }

    MixedAudioEngineHealth health;
    memset(&health, 0, sizeof(health));
    int32_t status = mixed_audio_session_get_health(gMixer.session, &health);
    pthread_mutex_unlock(&gMixer.mutex);
    if (status != 0) {
        return status;
    }

    outCounters[kMCALiveMixerHealthFramesMixed] = health.frames_mixed;
    outCounters[kMCALiveMixerHealthSystemUnderrunFrames] = health.system_underrun_frames;
    outCounters[kMCALiveMixerHealthMicUnderrunFrames] = health.mic_underrun_frames;
    outCounters[kMCALiveMixerHealthClippedSamples] = health.clipped_samples;
    outCounters[kMCALiveMixerHealthSystemQueueFrames] = health.system_queue_frames;
    outCounters[kMCALiveMixerHealthMicQueueFrames] = health.mic_queue_frames;
    outCounters[kMCALiveMixerHealthSourceFrameDelta] = MCASignedInt32Bits(health.source_frame_delta);
    outCounters[kMCALiveMixerHealthSourceFrameDeltaAbs] = health.source_frame_delta_abs;
    outCounters[kMCALiveMixerHealthSystemDriftDropFrames] = health.system_drift_drop_frames;
    outCounters[kMCALiveMixerHealthMicDriftDropFrames] = health.mic_drift_drop_frames;
    outCounters[kMCALiveMixerHealthCallbackErrorCount] = health.callback_error_count;
    return 0;
}
