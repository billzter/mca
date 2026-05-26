#import <AudioToolbox/AudioQueue.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

#include <pthread.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "MixedAudioEngine.h"
#include "MixedAudioSharedMemory.h"
#include "LiveMixerABI.h"

static const useconds_t kMCAAggregateTapSettleMicros = 300000;

enum {
    kMCAOutputSampleRate = 48000,
    kMCAOutputChannels = 2,
    kMCAMicBufferFrameCount = 512,
    kMCAMicBufferCount = 3,
    kMCASharedMemoryCapacityFrames = 12000,
    kMCAMaxWriteFrames = 2400,
    kMCAMaxTapScratchFrames = 4096,
    kMCAProgramGraphFadeFrames = 480,
    kMCASourceQueueCapacityFrames = 48000,
    kMCAMixerTickFrames = 512,
    kMCAMixerIdleMicros = 1000
};

typedef struct MCAAudioFrameQueue {
    atomic_uint_fast64_t readFrameIndex;
    atomic_uint_fast64_t writeFrameIndex;
    atomic_uint_fast64_t droppedFrameCount;
    UInt32 capacityFrames;
    UInt32 channelCount;
    float *samples;
} MCAAudioFrameQueue;

typedef struct MCALiveMixerContext {
    pthread_mutex_t mutex;
    atomic_bool micStopping;
    atomic_bool mixerActive;
    atomic_bool mixerThreadStarted;
    atomic_bool resetSourcesRequested;
    atomic_uint_fast32_t bridgeSilenceFramesRequested;
    atomic_uint_fast32_t graphFadeInFramesRemaining;
    bool running;
    AudioObjectID tapID;
    AudioObjectID aggregateID;
    AudioDeviceIOProcID ioProcID;
    AudioQueueRef micQueue;
    AudioQueueBufferRef micBuffers[kMCAMicBufferCount];
    AudioStreamBasicDescription tapFormat;
    AudioStreamBasicDescription micFormat;
    MixedAudioSessionHandle *session;
    MixedAudioEngineHealth cachedHealth;
    pthread_t mixerThread;
    MCAAudioFrameQueue systemQueue;
    MCAAudioFrameQueue micQueueFrames;
    float systemQueueStorage[kMCASourceQueueCapacityFrames * kMCAOutputChannels];
    float micQueueStorage[kMCASourceQueueCapacityFrames];
    float mixerSystemScratch[kMCAMixerTickFrames * kMCAOutputChannels];
    float mixerMicScratch[kMCAMixerTickFrames];
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
    kMCALiveMixerHealthSharedRingFillFrames = 11,
    kMCALiveMixerHealthSharedRingFillErrorFrames = 12,
    kMCALiveMixerHealthSharedRingFillErrorAbsFrames = 13,
    kMCALiveMixerHealthSharedRingOverrunFrames = 14,
    kMCALiveMixerHealthSystemQueueDroppedFrames = 15,
    kMCALiveMixerHealthMicQueueDroppedFrames = 16,
    kMCALiveMixerHealthCounterCount = 17
};

static uint64_t MCASignedInt32Bits(int32_t value)
{
    return (uint64_t)(int64_t)value;
}

static MCALiveMixerContext gMixer;
static pthread_once_t gMixerOnce = PTHREAD_ONCE_INIT;
static const char *kMCANoMicrophoneUID = "__MCA_NO_MIC__";

static void *MCAMixerOwnerThreadMain(void *userData);

static uint64_t MCAMachTicksForAudioFrames(UInt32 frames)
{
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);

    uint64_t nanos = ((uint64_t)frames * 1000000000ULL) / kMCAOutputSampleRate;
    return (nanos * timebase.denom) / timebase.numer;
}

static void MCAAudioFrameQueueConfigure(MCAAudioFrameQueue *queue,
                                        float *storage,
                                        UInt32 capacityFrames,
                                        UInt32 channelCount)
{
    atomic_init(&queue->readFrameIndex, 0);
    atomic_init(&queue->writeFrameIndex, 0);
    atomic_init(&queue->droppedFrameCount, 0);
    queue->capacityFrames = capacityFrames;
    queue->channelCount = channelCount;
    queue->samples = storage;
}

static void MCAAudioFrameQueueReset(MCAAudioFrameQueue *queue)
{
    uint_fast64_t writeIndex = atomic_load_explicit(&queue->writeFrameIndex,
                                                   memory_order_acquire);
    atomic_store_explicit(&queue->readFrameIndex, writeIndex, memory_order_release);
}

static UInt32 MCAAudioFrameQueuePush(MCAAudioFrameQueue *queue,
                                     const float *samples,
                                     UInt32 frames)
{
    if (queue == NULL || queue->samples == NULL || samples == NULL || frames == 0) {
        return 0;
    }

    UInt32 framesToWrite = frames;
    if (framesToWrite > queue->capacityFrames) {
        UInt32 droppedFrames = framesToWrite - queue->capacityFrames;
        atomic_fetch_add_explicit(&queue->droppedFrameCount,
                                  droppedFrames,
                                  memory_order_relaxed);
        framesToWrite = queue->capacityFrames;
    }

    uint_fast64_t readIndex = atomic_load_explicit(&queue->readFrameIndex,
                                                  memory_order_acquire);
    uint_fast64_t writeIndex = atomic_load_explicit(&queue->writeFrameIndex,
                                                   memory_order_relaxed);
    uint_fast64_t queuedFrames = writeIndex - readIndex;
    if (queuedFrames >= queue->capacityFrames) {
        atomic_fetch_add_explicit(&queue->droppedFrameCount,
                                  framesToWrite,
                                  memory_order_relaxed);
        return 0;
    }

    UInt32 availableFrames = queue->capacityFrames - (UInt32)queuedFrames;
    if (framesToWrite > availableFrames) {
        UInt32 droppedFrames = framesToWrite - availableFrames;
        atomic_fetch_add_explicit(&queue->droppedFrameCount,
                                  droppedFrames,
                                  memory_order_relaxed);
        framesToWrite = availableFrames;
    }
    if (framesToWrite == 0) {
        return 0;
    }

    UInt32 channelCount = queue->channelCount;
    UInt32 startFrame = (UInt32)(writeIndex % queue->capacityFrames);
    UInt32 firstFrames = queue->capacityFrames - startFrame;
    if (firstFrames > framesToWrite) {
        firstFrames = framesToWrite;
    }
    memcpy(&queue->samples[(size_t)startFrame * channelCount],
           samples,
           sizeof(float) * firstFrames * channelCount);

    UInt32 remainingFrames = framesToWrite - firstFrames;
    if (remainingFrames > 0) {
        memcpy(queue->samples,
               &samples[(size_t)firstFrames * channelCount],
               sizeof(float) * remainingFrames * channelCount);
    }

    atomic_store_explicit(&queue->writeFrameIndex,
                          writeIndex + framesToWrite,
                          memory_order_release);
    return framesToWrite;
}

static UInt32 MCAAudioFrameQueuePop(MCAAudioFrameQueue *queue,
                                    float *outSamples,
                                    UInt32 maxFrames)
{
    if (queue == NULL || queue->samples == NULL || outSamples == NULL || maxFrames == 0) {
        return 0;
    }

    uint_fast64_t readIndex = atomic_load_explicit(&queue->readFrameIndex,
                                                  memory_order_relaxed);
    uint_fast64_t writeIndex = atomic_load_explicit(&queue->writeFrameIndex,
                                                   memory_order_acquire);
    uint_fast64_t queuedFrames = writeIndex - readIndex;
    if (queuedFrames == 0) {
        return 0;
    }

    UInt32 framesToRead = queuedFrames > maxFrames ? maxFrames : (UInt32)queuedFrames;
    UInt32 channelCount = queue->channelCount;
    UInt32 startFrame = (UInt32)(readIndex % queue->capacityFrames);
    UInt32 firstFrames = queue->capacityFrames - startFrame;
    if (firstFrames > framesToRead) {
        firstFrames = framesToRead;
    }
    memcpy(outSamples,
           &queue->samples[(size_t)startFrame * channelCount],
           sizeof(float) * firstFrames * channelCount);

    UInt32 remainingFrames = framesToRead - firstFrames;
    if (remainingFrames > 0) {
        memcpy(&outSamples[(size_t)firstFrames * channelCount],
               queue->samples,
               sizeof(float) * remainingFrames * channelCount);
    }

    atomic_store_explicit(&queue->readFrameIndex,
                          readIndex + framesToRead,
                          memory_order_release);
    return framesToRead;
}

static void MCAInitMixer(void)
{
    memset(&gMixer, 0, sizeof(gMixer));
    pthread_mutex_init(&gMixer.mutex, NULL);
    MCAAudioFrameQueueConfigure(&gMixer.systemQueue,
                                gMixer.systemQueueStorage,
                                kMCASourceQueueCapacityFrames,
                                kMCAOutputChannels);
    MCAAudioFrameQueueConfigure(&gMixer.micQueueFrames,
                                gMixer.micQueueStorage,
                                kMCASourceQueueCapacityFrames,
                                1);
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

static MixedAudioSessionHandle *MCACreateRustSession(void)
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

    return mixed_audio_session_create(config);
}

static bool MCAEnsureRustSession(MCALiveMixerContext *context)
{
    pthread_mutex_lock(&context->mutex);
    if (context->session != NULL) {
        pthread_mutex_unlock(&context->mutex);
        return true;
    }
    pthread_mutex_unlock(&context->mutex);

    MixedAudioSessionHandle *session = MCACreateRustSession();
    if (session == NULL) {
        return false;
    }

    bool didPublishSession = false;
    pthread_mutex_lock(&context->mutex);
    if (context->session == NULL) {
        context->session = session;
        memset(&context->cachedHealth, 0, sizeof(context->cachedHealth));
        atomic_store_explicit(&context->systemQueue.droppedFrameCount, 0, memory_order_release);
        atomic_store_explicit(&context->micQueueFrames.droppedFrameCount, 0, memory_order_release);
        didPublishSession = true;
    }
    pthread_mutex_unlock(&context->mutex);

    if (!didPublishSession) {
        mixed_audio_session_destroy(session);
    }
    return true;
}

static bool MCAEnsureMixerOwnerThread(MCALiveMixerContext *context)
{
    if (atomic_load_explicit(&context->mixerThreadStarted, memory_order_acquire)) {
        return true;
    }

    pthread_mutex_lock(&context->mutex);
    if (atomic_load_explicit(&context->mixerThreadStarted, memory_order_relaxed)) {
        pthread_mutex_unlock(&context->mutex);
        return true;
    }

    int status = pthread_create(&context->mixerThread,
                                NULL,
                                MCAMixerOwnerThreadMain,
                                context);
    if (status != 0) {
        pthread_mutex_unlock(&context->mutex);
        return false;
    }
    pthread_detach(context->mixerThread);
    atomic_store_explicit(&context->mixerThreadStarted, true, memory_order_release);
    pthread_mutex_unlock(&context->mutex);
    return true;
}

static void MCARequestRustSourceReset(MCALiveMixerContext *context)
{
    atomic_store_explicit(&context->graphFadeInFramesRemaining, 0, memory_order_release);
    atomic_store_explicit(&context->resetSourcesRequested, true, memory_order_release);
}

static void MCAResetSourceQueuesOnMixerOwner(MCALiveMixerContext *context)
{
    MCAAudioFrameQueueReset(&context->systemQueue);
    MCAAudioFrameQueueReset(&context->micQueueFrames);
}

static void MCAArmProgramGraphFadeIn(MCALiveMixerContext *context)
{
    atomic_store_explicit(&context->graphFadeInFramesRemaining,
                          kMCAProgramGraphFadeFrames,
                          memory_order_release);
}

static void MCAApplyProgramGraphFadeInLocked(MCALiveMixerContext *context,
                                             float *samples,
                                             UInt32 frames)
{
    uint_fast32_t remaining = atomic_load_explicit(&context->graphFadeInFramesRemaining,
                                                  memory_order_acquire);
    if (remaining == 0 || samples == NULL || frames == 0) {
        return;
    }

    UInt32 fadeFrames = 0;
    bool claimedFadeFrames = false;
    while (remaining > 0) {
        fadeFrames = remaining < frames ? (UInt32)remaining : frames;
        uint_fast32_t nextRemaining = remaining - fadeFrames;
        if (atomic_compare_exchange_weak_explicit(&context->graphFadeInFramesRemaining,
                                                  &remaining,
                                                  nextRemaining,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire)) {
            claimedFadeFrames = true;
            break;
        }
    }
    if (!claimedFadeFrames || fadeFrames == 0) {
        return;
    }

    UInt32 fadeCompleted = kMCAProgramGraphFadeFrames - (UInt32)remaining;
    for (UInt32 frame = 0; frame < fadeFrames; frame++) {
        float gain = (float)(fadeCompleted + frame + 1) / (float)kMCAProgramGraphFadeFrames;
        samples[(size_t)frame * kMCAOutputChannels] *= gain;
        samples[(size_t)frame * kMCAOutputChannels + 1] *= gain;
    }
}

static void MCARequestProgramGraphBridgeSilence(MCALiveMixerContext *context)
{
    if (context == NULL) {
        return;
    }

    atomic_fetch_add_explicit(&context->bridgeSilenceFramesRequested,
                              kMCAProgramGraphFadeFrames,
                              memory_order_acq_rel);
}

static void MCARefreshCachedHealthLocked(MCALiveMixerContext *context)
{
    if (context == NULL || context->session == NULL) {
        return;
    }

    MixedAudioEngineHealth health;
    memset(&health, 0, sizeof(health));
    if (mixed_audio_session_get_health(context->session, &health) == 0) {
        context->cachedHealth = health;
    }
}

static void MCAMixerOwnerProcessTickLocked(MCALiveMixerContext *context)
{
    if (context == NULL) {
        return;
    }

    uint_fast32_t bridgeFrames = atomic_load_explicit(&context->bridgeSilenceFramesRequested,
                                                     memory_order_acquire);
    if (context->session != NULL && bridgeFrames > 0) {
        UInt32 frames = 0;
        bool claimedBridgeFrames = false;
        while (bridgeFrames > 0) {
            frames = bridgeFrames > kMCAMixerTickFrames
                         ? kMCAMixerTickFrames
                         : (UInt32)bridgeFrames;
            if (atomic_compare_exchange_weak_explicit(&context->bridgeSilenceFramesRequested,
                                                      &bridgeFrames,
                                                      bridgeFrames - frames,
                                                      memory_order_acq_rel,
                                                      memory_order_acquire)) {
                claimedBridgeFrames = true;
                break;
            }
        }
        if (!claimedBridgeFrames || frames == 0) {
            return;
        }
        memset(context->mixerSystemScratch,
               0,
               sizeof(float) * frames * kMCAOutputChannels);
        (void)mixed_audio_session_push_system_interleaved_stereo(context->session,
                                                                 context->mixerSystemScratch,
                                                                 frames);
        (void)mixed_audio_session_mix_and_write(context->session, frames);
        MCARefreshCachedHealthLocked(context);
        return;
    }

    if (atomic_exchange_explicit(&context->resetSourcesRequested,
                                 false,
                                 memory_order_acq_rel)) {
        MCAResetSourceQueuesOnMixerOwner(context);
        if (context->session != NULL) {
            (void)mixed_audio_session_reset_sources(context->session);
            MCARefreshCachedHealthLocked(context);
        }
    }

    if (context->session == NULL) {
        return;
    }

    UInt32 systemFrames = MCAAudioFrameQueuePop(&context->systemQueue,
                                                context->mixerSystemScratch,
                                                kMCAMixerTickFrames);
    if (systemFrames > 0) {
        MCAApplyProgramGraphFadeInLocked(context, context->mixerSystemScratch, systemFrames);
        (void)mixed_audio_session_push_system_interleaved_stereo(context->session,
                                                                 context->mixerSystemScratch,
                                                                 systemFrames);
    }

    UInt32 micFrames = MCAAudioFrameQueuePop(&context->micQueueFrames,
                                             context->mixerMicScratch,
                                             kMCAMixerTickFrames);
    if (micFrames > 0) {
        (void)mixed_audio_session_push_mic_mono(context->session,
                                                context->mixerMicScratch,
                                                micFrames);
    }

    (void)mixed_audio_session_mix_and_write(context->session, kMCAMixerTickFrames);
    MCARefreshCachedHealthLocked(context);
}

static void *MCAMixerOwnerThreadMain(void *userData)
{
    MCALiveMixerContext *context = (MCALiveMixerContext *)userData;
    uint64_t tickInterval = MCAMachTicksForAudioFrames(kMCAMixerTickFrames);
    uint64_t nextTick = mach_absolute_time();
    while (true) {
        bool active = atomic_load_explicit(&context->mixerActive, memory_order_acquire);
        bool hasBridge = atomic_load_explicit(&context->bridgeSilenceFramesRequested,
                                              memory_order_acquire) > 0;
        bool hasReset = atomic_load_explicit(&context->resetSourcesRequested,
                                             memory_order_acquire);
        if (!active && !hasBridge && !hasReset) {
            usleep(kMCAMixerIdleMicros);
            nextTick = mach_absolute_time();
            continue;
        }

        uint64_t tickStart = mach_absolute_time();
        if (tickStart > nextTick + tickInterval) {
            nextTick = tickStart;
        }

        pthread_mutex_lock(&context->mutex);
        MCAMixerOwnerProcessTickLocked(context);
        pthread_mutex_unlock(&context->mutex);

        nextTick += tickInterval;
        uint64_t afterTick = mach_absolute_time();
        if (nextTick > afterTick) {
            mach_wait_until(nextTick);
        } else {
            nextTick = afterTick;
        }
    }

    return NULL;
}

// Realtime callback boundary: these enqueue helpers and the Core Audio callbacks below must
// only copy into preallocated queues and return. Keep mutexes and mixed_audio_session_* calls
// on MCAMixerOwnerThreadMain, where blocking control-plane work cannot stall the audio callback.
static void MCAEnqueueSystemFrames(MCALiveMixerContext *context,
                                   const float *samples,
                                   UInt32 frames)
{
    if (context == NULL || samples == NULL || frames == 0) {
        return;
    }

    (void)MCAAudioFrameQueuePush(&context->systemQueue, samples, frames);
}

static void MCAEnqueueMicFrames(MCALiveMixerContext *context,
                                const float *samples,
                                UInt32 frames)
{
    if (context == NULL || samples == NULL || frames == 0) {
        return;
    }

    (void)MCAAudioFrameQueuePush(&context->micQueueFrames, samples, frames);
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
    MCAEnqueueSystemFrames(context, (const float *)buffer->mData, frames);
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
    const float *left = (const float *)inputData->mBuffers[0].mData;
    const float *right = (const float *)inputData->mBuffers[1].mData;
    if (left == NULL || right == NULL) {
        return;
    }

    UInt32 offset = 0;
    while (offset < frames) {
        UInt32 chunkFrames = frames - offset;
        if (chunkFrames > kMCAMaxTapScratchFrames) {
            chunkFrames = kMCAMaxTapScratchFrames;
        }
        for (UInt32 frame = 0; frame < chunkFrames; frame++) {
            context->tapScratch[(size_t)frame * kMCAOutputChannels] = left[offset + frame];
            context->tapScratch[(size_t)frame * kMCAOutputChannels + 1] = right[offset + frame];
        }
        MCAEnqueueSystemFrames(context, context->tapScratch, chunkFrames);
        offset += chunkFrames;
    }
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
        MCAEnqueueMicFrames(context, (const float *)buffer->mAudioData, frames);
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

static void MCAStopSourceGraph(MCALiveMixerContext *context, bool shouldBridge)
{
    if (!shouldBridge) {
        atomic_store_explicit(&context->mixerActive, false, memory_order_release);
        atomic_store_explicit(&context->bridgeSilenceFramesRequested, 0, memory_order_release);
    }

    bool wasRunning = false;
    pthread_mutex_lock(&context->mutex);
    wasRunning = context->running;
    context->running = false;
    pthread_mutex_unlock(&context->mutex);

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
    MCARequestRustSourceReset(context);
    if (shouldBridge && wasRunning) {
        MCARequestProgramGraphBridgeSilence(context);
    }
    pthread_mutex_lock(&context->mutex);
    memset(context->micBuffers, 0, sizeof(context->micBuffers));
    memset(&context->tapFormat, 0, sizeof(context->tapFormat));
    memset(&context->micFormat, 0, sizeof(context->micFormat));
    pthread_mutex_unlock(&context->mutex);
}

static void MCACleanup(MCALiveMixerContext *context)
{
    atomic_store_explicit(&context->mixerActive, false, memory_order_release);
    atomic_store_explicit(&context->bridgeSilenceFramesRequested, 0, memory_order_release);
    atomic_store_explicit(&context->resetSourcesRequested, false, memory_order_release);
    MCAStopSourceGraph(context, false);
}

int32_t MCA_LiveMixerStart(const char *microphoneUID,
                           int32_t captureMode,
                           const char *selectedAppBundleIDs)
{
    pthread_once(&gMixerOnce, MCAInitMixer);

    if (!MCAEnsureMixerOwnerThread(&gMixer)) {
        return -9;
    }

    MCAStopSourceGraph(&gMixer, true);
    if (!MCAEnsureRustSession(&gMixer)) {
        return -6;
    }
    MCARequestRustSourceReset(&gMixer);

    atomic_store(&gMixer.micStopping, false);
    atomic_store_explicit(&gMixer.mixerActive, true, memory_order_release);

    @autoreleasepool {
        AudioObjectID ownProcessObject = MCACopyCurrentProcessObject();
        NSArray<NSNumber *> *excludedProcesses =
            ownProcessObject == kAudioObjectUnknown
                ? @[]
                : @[ [NSNumber numberWithUnsignedInt:ownProcessObject] ];

        NSUUID *tapUUID = [NSUUID UUID];
        NSString *tapUID = [tapUUID UUIDString];
        CATapDescription *tapDescription = nil;
        if (captureMode == MCA_LIVE_MIXER_CAPTURE_MODE_SELECTED_APPS) {
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
            MCAStopSourceGraph(&gMixer, false);
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
            MCAStopSourceGraph(&gMixer, false);
            return -2;
        }

        if (!MCASetAggregateTapList(gMixer.aggregateID, tapUID)) {
            MCAStopSourceGraph(&gMixer, false);
            return -3;
        }

        usleep(kMCAAggregateTapSettleMicros);
        if (!MCACopyAggregateInputFormat(gMixer.aggregateID, &gMixer.tapFormat)) {
            MCAStopSourceGraph(&gMixer, false);
            return -4;
        }

        status = AudioDeviceCreateIOProcID(gMixer.aggregateID,
                                           MCATapIOProc,
                                           &gMixer,
                                           &gMixer.ioProcID);
        if (status != noErr) {
            MCAStopSourceGraph(&gMixer, false);
            return -5;
        }

        bool shouldStartMicrophone =
            microphoneUID == NULL || strcmp(microphoneUID, kMCANoMicrophoneUID) != 0;
        if (shouldStartMicrophone) {
            if (!MCAStartMicrophoneQueue(&gMixer, microphoneUID)) {
                MCAStopSourceGraph(&gMixer, false);
                return -7;
            }
        }

        MCAArmProgramGraphFadeIn(&gMixer);
        status = AudioDeviceStart(gMixer.aggregateID, gMixer.ioProcID);
        if (status != noErr) {
            MCAStopSourceGraph(&gMixer, false);
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
    // Stop means "no active source graph" during setup/mode changes. Keep the Rust session and
    // shared-memory object alive so existing HAL clients do not stay mapped to an unlinked object.
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

    MixedAudioEngineHealth health = gMixer.cachedHealth;
    uint64_t systemQueueDroppedFrames =
        atomic_load_explicit(&gMixer.systemQueue.droppedFrameCount, memory_order_relaxed);
    uint64_t micQueueDroppedFrames =
        atomic_load_explicit(&gMixer.micQueueFrames.droppedFrameCount, memory_order_relaxed);
    pthread_mutex_unlock(&gMixer.mutex);

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
    outCounters[kMCALiveMixerHealthSharedRingFillFrames] = health.shared_ring_fill_frames;
    outCounters[kMCALiveMixerHealthSharedRingFillErrorFrames] =
        MCASignedInt32Bits(health.shared_ring_fill_error_frames);
    outCounters[kMCALiveMixerHealthSharedRingFillErrorAbsFrames] =
        health.shared_ring_fill_error_abs_frames;
    outCounters[kMCALiveMixerHealthSharedRingOverrunFrames] =
        health.shared_ring_overrun_frames;
    outCounters[kMCALiveMixerHealthSystemQueueDroppedFrames] = systemQueueDroppedFrames;
    outCounters[kMCALiveMixerHealthMicQueueDroppedFrames] = micQueueDroppedFrames;
    return 0;
}
