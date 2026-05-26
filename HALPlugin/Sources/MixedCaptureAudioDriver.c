#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <stddef.h>
#include <string.h>

#include "MixedCaptureAudioCompatibility.h"
#include "MixedAudioSharedMemory.h"
#include "MixedAudioSharedMemoryProbe.h"
#include "MixedAudioSharedMemoryReader.h"

enum {
    kMixedAudioObjectID_Device = 2,
    kMixedAudioObjectID_InputStream = 3,
    kMixedAudioDefaultBufferFrameSize = 512,
    kMixedAudioZeroTimeStampPeriod = 16384
};

static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gReferenceCount = 1;
static UInt32 gActiveIOClientCount = 0;
static UInt64 gStartHostTime = 0;
static mach_timebase_info_data_t gTimebase = {0, 0};
static mixed_audio_shm_reader_t gSharedMemoryReader;

static HRESULT MixedAudio_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG MixedAudio_AddRef(void *inDriver);
static ULONG MixedAudio_Release(void *inDriver);
static OSStatus MixedAudio_Initialize(AudioServerPlugInDriverRef inDriver,
                                      AudioServerPlugInHostRef inHost);
static OSStatus MixedAudio_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                        CFDictionaryRef inDescription,
                                        const AudioServerPlugInClientInfo *inClientInfo,
                                        AudioObjectID *outDeviceObjectID);
static OSStatus MixedAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID);
static OSStatus MixedAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inDeviceObjectID,
                                           const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus MixedAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inDeviceObjectID,
                                              const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus MixedAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                            AudioObjectID inDeviceObjectID,
                                                            UInt64 inChangeAction,
                                                            void *inChangeInfo);
static OSStatus MixedAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                          AudioObjectID inDeviceObjectID,
                                                          UInt64 inChangeAction,
                                                          void *inChangeInfo);
static Boolean MixedAudio_HasProperty(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress);
static OSStatus MixedAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inObjectID,
                                              pid_t inClientProcessID,
                                              const AudioObjectPropertyAddress *inAddress,
                                              Boolean *outIsSettable);
static OSStatus MixedAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inObjectID,
                                               pid_t inClientProcessID,
                                               const AudioObjectPropertyAddress *inAddress,
                                               UInt32 inQualifierDataSize,
                                               const void *inQualifierData,
                                               UInt32 *outDataSize);
static OSStatus MixedAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress *inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void *inQualifierData,
                                           UInt32 inDataSize,
                                           UInt32 *outDataSize,
                                           void *outData);
static OSStatus MixedAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress *inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void *inQualifierData,
                                           UInt32 inDataSize,
                                           const void *inData);
static OSStatus MixedAudio_StartIO(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inDeviceObjectID,
                                   UInt32 inClientID);
static OSStatus MixedAudio_StopIO(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inDeviceObjectID,
                                  UInt32 inClientID);
static OSStatus MixedAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt32 inClientID,
                                            Float64 *outSampleTime,
                                            UInt64 *outHostTime,
                                            UInt64 *outSeed);
static OSStatus MixedAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID inDeviceObjectID,
                                             UInt32 inClientID,
                                             UInt32 inOperationID,
                                             Boolean *outWillDo,
                                             Boolean *outWillDoInPlace);
static OSStatus MixedAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt32 inClientID,
                                            UInt32 inOperationID,
                                            UInt32 inIOBufferFrameSize,
                                            const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus MixedAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID,
                                         AudioObjectID inStreamObjectID,
                                         UInt32 inClientID,
                                         UInt32 inOperationID,
                                         UInt32 inIOBufferFrameSize,
                                         const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                         void *ioMainBuffer,
                                         void *ioSecondaryBuffer);
static OSStatus MixedAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID,
                                          UInt32 inOperationID,
                                          UInt32 inIOBufferFrameSize,
                                          const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    MixedAudio_QueryInterface,
    MixedAudio_AddRef,
    MixedAudio_Release,
    MixedAudio_Initialize,
    MixedAudio_CreateDevice,
    MixedAudio_DestroyDevice,
    MixedAudio_AddDeviceClient,
    MixedAudio_RemoveDeviceClient,
    MixedAudio_PerformDeviceConfigurationChange,
    MixedAudio_AbortDeviceConfigurationChange,
    MixedAudio_HasProperty,
    MixedAudio_IsPropertySettable,
    MixedAudio_GetPropertyDataSize,
    MixedAudio_GetPropertyData,
    MixedAudio_SetPropertyData,
    MixedAudio_StartIO,
    MixedAudio_StopIO,
    MixedAudio_GetZeroTimeStamp,
    MixedAudio_WillDoIOOperation,
    MixedAudio_BeginIOOperation,
    MixedAudio_DoIOOperation,
    MixedAudio_EndIOOperation
};

static AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;

static Boolean uuid_matches(CFUUIDRef uuid, REFIID iid)
{
    CFUUIDBytes bytes = CFUUIDGetUUIDBytes(uuid);
    return memcmp(&bytes, &iid, sizeof(CFUUIDBytes)) == 0;
}

static Boolean is_main_element(const AudioObjectPropertyAddress *address)
{
    return address != NULL &&
           (address->mElement == kAudioObjectPropertyElementMain ||
            address->mElement == kAudioObjectPropertyElementWildcard);
}

static Boolean scope_matches(AudioObjectPropertyScope actual, AudioObjectPropertyScope expected)
{
    return actual == expected || actual == kAudioObjectPropertyScopeWildcard;
}

static Boolean is_global_property(const AudioObjectPropertyAddress *address)
{
    return is_main_element(address) && scope_matches(address->mScope, kAudioObjectPropertyScopeGlobal);
}

static Boolean is_input_property(const AudioObjectPropertyAddress *address)
{
    return is_main_element(address) && scope_matches(address->mScope, kAudioObjectPropertyScopeInput);
}

static Boolean is_output_property(const AudioObjectPropertyAddress *address)
{
    return is_main_element(address) && scope_matches(address->mScope, kAudioObjectPropertyScopeOutput);
}

static AudioStreamBasicDescription stream_description(void)
{
    AudioStreamBasicDescription description;
    memset(&description, 0, sizeof(description));
    description.mSampleRate = MIXED_AUDIO_OUTPUT_SAMPLE_RATE;
    description.mFormatID = kAudioFormatLinearPCM;
    description.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    description.mBytesPerPacket = MIXED_AUDIO_OUTPUT_CHANNEL_COUNT * sizeof(Float32);
    description.mFramesPerPacket = 1;
    description.mBytesPerFrame = MIXED_AUDIO_OUTPUT_CHANNEL_COUNT * sizeof(Float32);
    description.mChannelsPerFrame = MIXED_AUDIO_OUTPUT_CHANNEL_COUNT;
    description.mBitsPerChannel = sizeof(Float32) * 8;
    return description;
}

static UInt32 stream_configuration_size(UInt32 buffer_count)
{
    return (UInt32)(offsetof(AudioBufferList, mBuffers) + (sizeof(AudioBuffer) * buffer_count));
}

static void write_stream_configuration(AudioBufferList *buffer_list, UInt32 buffer_count)
{
    buffer_list->mNumberBuffers = buffer_count;
    if (buffer_count > 0) {
        buffer_list->mBuffers[0].mNumberChannels = MIXED_AUDIO_OUTPUT_CHANNEL_COUNT;
        buffer_list->mBuffers[0].mDataByteSize = 0;
        buffer_list->mBuffers[0].mData = NULL;
    }
}

static OSStatus write_data(UInt32 required_size,
                           UInt32 inDataSize,
                           UInt32 *outDataSize,
                           void *outData,
                           const void *source)
{
    if (outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (inDataSize < required_size) {
        *outDataSize = 0;
        return kAudioHardwareBadPropertySizeError;
    }
    memcpy(outData, source, required_size);
    *outDataSize = required_size;
    return noErr;
}

static OSStatus write_cfstring(UInt32 inDataSize,
                               UInt32 *outDataSize,
                               void *outData,
                               CFStringRef value)
{
    if (outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (inDataSize < sizeof(CFStringRef)) {
        *outDataSize = 0;
        return kAudioHardwareBadPropertySizeError;
    }
    CFStringRef copy = CFStringCreateCopy(kCFAllocatorDefault, value);
    if (copy == NULL) {
        *outDataSize = 0;
        return kAudioHardwareUnspecifiedError;
    }
    *((CFStringRef *)outData) = copy;
    *outDataSize = sizeof(CFStringRef);
    return noErr;
}

static uint64_t host_time_to_nanos(uint64_t host_time)
{
    if (gTimebase.denom == 0) {
        return 0;
    }
    return host_time * (uint64_t)gTimebase.numer / (uint64_t)gTimebase.denom;
}

static uint64_t io_cycle_now_nanos(const AudioServerPlugInIOCycleInfo *cycle_info)
{
    if (cycle_info != NULL &&
        (cycle_info->mCurrentTime.mFlags & kAudioTimeStampHostTimeValid) != 0 &&
        cycle_info->mCurrentTime.mHostTime != 0) {
        return host_time_to_nanos(cycle_info->mCurrentTime.mHostTime);
    }
    return host_time_to_nanos(mach_absolute_time());
}

static void read_shared_memory_audio(void *buffer,
                                     UInt32 frame_count,
                                     const AudioServerPlugInIOCycleInfo *cycle_info)
{
    if (buffer == NULL || frame_count == 0) {
        return;
    }

    uint64_t now_nanos = io_cycle_now_nanos(cycle_info);
    mixed_audio_shm_reader_read_at_time(&gSharedMemoryReader,
                                        (float *)buffer,
                                        frame_count,
                                        now_nanos,
                                        NULL);
}

static HRESULT MixedAudio_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
    (void)inDriver;

    if (outInterface == NULL) {
        return E_POINTER;
    }

    if (uuid_matches(kAudioServerPlugInDriverInterfaceUUID, inUUID) ||
        uuid_matches(IUnknownUUID, inUUID)) {
        MixedAudio_AddRef(&gDriverInterfacePtr);
        *outInterface = &gDriverInterfacePtr;
        return S_OK;
    }

    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG MixedAudio_AddRef(void *inDriver)
{
    (void)inDriver;
    return ++gReferenceCount;
}

static ULONG MixedAudio_Release(void *inDriver)
{
    (void)inDriver;
    if (gReferenceCount > 0) {
        gReferenceCount--;
    }
    return gReferenceCount;
}

static OSStatus MixedAudio_Initialize(AudioServerPlugInDriverRef inDriver,
                                      AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    gHost = inHost;
    gStartHostTime = mach_absolute_time();
    mach_timebase_info(&gTimebase);
    mixed_audio_shm_reader_init(&gSharedMemoryReader);

    mixed_audio_shm_probe_result_t probe = mixed_audio_shm_probe(MIXED_AUDIO_SHM_NAME);
    os_log(OS_LOG_DEFAULT,
           "MixedCaptureAudio: shared memory probe status=%{public}s errno=%d generation=%llu write_frame_index=%llu heartbeat=%llu marker_left_milli=%d marker_right_milli=%d",
           mixed_audio_shm_probe_status_string(probe.status),
           probe.error_number,
           probe.generation,
           probe.write_frame_index,
           probe.heartbeat_nanos,
           (int)(probe.marker_left * 1000.0f),
           (int)(probe.marker_right * 1000.0f));

    mixed_audio_shm_reader_status_t reader_status =
        mixed_audio_shm_reader_open(&gSharedMemoryReader, MIXED_AUDIO_SHM_NAME);
    os_log(OS_LOG_DEFAULT,
           "MixedCaptureAudio: shared memory reader setup status=%{public}s errno=%d",
           mixed_audio_shm_reader_status_string(reader_status),
           gSharedMemoryReader.last_errno);

    return noErr;
}

static OSStatus MixedAudio_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                        CFDictionaryRef inDescription,
                                        const AudioServerPlugInClientInfo *inClientInfo,
                                        AudioObjectID *outDeviceObjectID)
{
    (void)inDriver;
    (void)inDescription;
    (void)inClientInfo;
    if (outDeviceObjectID == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    *outDeviceObjectID = kAudioObjectUnknown;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MixedAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MixedAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inDeviceObjectID,
                                           const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver;
    (void)inClientInfo;
    return inDeviceObjectID == kMixedAudioObjectID_Device ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus MixedAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inDeviceObjectID,
                                              const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver;
    (void)inClientInfo;
    return inDeviceObjectID == kMixedAudioObjectID_Device ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus MixedAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                            AudioObjectID inDeviceObjectID,
                                                            UInt64 inChangeAction,
                                                            void *inChangeInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inChangeAction;
    (void)inChangeInfo;
    return noErr;
}

static OSStatus MixedAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                          AudioObjectID inDeviceObjectID,
                                                          UInt64 inChangeAction,
                                                          void *inChangeInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inChangeAction;
    (void)inChangeInfo;
    return noErr;
}

static Boolean MixedAudio_HasProperty(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress)
{
    (void)inDriver;
    (void)inClientProcessID;
    if (inAddress == NULL) {
        return false;
    }

    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            if (!is_global_property(inAddress)) {
                return false;
            }
            return inAddress->mSelector == kAudioObjectPropertyClass ||
                   inAddress->mSelector == kAudioObjectPropertyBaseClass ||
                   inAddress->mSelector == kAudioObjectPropertyOwner ||
                   inAddress->mSelector == kAudioObjectPropertyName ||
                   inAddress->mSelector == kAudioObjectPropertyManufacturer ||
                   inAddress->mSelector == kAudioObjectPropertyOwnedObjects ||
                   inAddress->mSelector == kAudioPlugInPropertyBoxList ||
                   inAddress->mSelector == kAudioPlugInPropertyTranslateUIDToBox ||
                   inAddress->mSelector == kAudioPlugInPropertyDeviceList ||
                   inAddress->mSelector == kAudioPlugInPropertyTranslateUIDToDevice ||
                   inAddress->mSelector == kAudioPlugInPropertyResourceBundle;

        case kMixedAudioObjectID_Device:
            if (is_global_property(inAddress)) {
                return inAddress->mSelector == kAudioObjectPropertyClass ||
                       inAddress->mSelector == kAudioObjectPropertyBaseClass ||
                       inAddress->mSelector == kAudioObjectPropertyOwner ||
                       inAddress->mSelector == kAudioObjectPropertyName ||
                       inAddress->mSelector == kAudioObjectPropertyManufacturer ||
                       inAddress->mSelector == kAudioObjectPropertyModelName ||
                       inAddress->mSelector == kAudioObjectPropertyOwnedObjects ||
                       inAddress->mSelector == kAudioDevicePropertyDeviceUID ||
                       inAddress->mSelector == kAudioDevicePropertyModelUID ||
                       inAddress->mSelector == kAudioDevicePropertyTransportType ||
                       inAddress->mSelector == kAudioDevicePropertyRelatedDevices ||
                       inAddress->mSelector == kAudioDevicePropertyClockDomain ||
                       inAddress->mSelector == kAudioDevicePropertyDeviceIsAlive ||
                       inAddress->mSelector == kAudioDevicePropertyDeviceIsRunning ||
                       inAddress->mSelector == kAudioDevicePropertyDeviceIsRunningSomewhere ||
                       inAddress->mSelector == kAudioObjectPropertyControlList ||
                       inAddress->mSelector == kAudioDevicePropertyNominalSampleRate ||
                       inAddress->mSelector == kAudioDevicePropertyAvailableNominalSampleRates ||
                       inAddress->mSelector == kAudioDevicePropertyIsHidden ||
                       inAddress->mSelector == kAudioDevicePropertyZeroTimeStampPeriod ||
                       inAddress->mSelector == kAudioDevicePropertyBufferFrameSize ||
                       inAddress->mSelector == kAudioDevicePropertyStreamConfiguration ||
                       inAddress->mSelector == kAudioDevicePropertyStreams ||
                       inAddress->mSelector == kMCAAudioDevicePropertyDriverCompatibilityVersion ||
                       inAddress->mSelector == kMCAAudioDevicePropertySharedMemoryABIVersion;
            }
            if (is_input_property(inAddress) || is_output_property(inAddress)) {
                return inAddress->mSelector == kAudioDevicePropertyStreamConfiguration ||
                       inAddress->mSelector == kAudioDevicePropertyStreams ||
                       inAddress->mSelector == kAudioDevicePropertyDeviceCanBeDefaultDevice ||
                       inAddress->mSelector == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice ||
                       inAddress->mSelector == kAudioDevicePropertyLatency ||
                       inAddress->mSelector == kAudioDevicePropertySafetyOffset ||
                       inAddress->mSelector == kAudioDevicePropertyPreferredChannelsForStereo;
            }
            return false;

        case kMixedAudioObjectID_InputStream:
            if (!is_global_property(inAddress)) {
                return false;
            }
            return inAddress->mSelector == kAudioObjectPropertyClass ||
                   inAddress->mSelector == kAudioObjectPropertyBaseClass ||
                   inAddress->mSelector == kAudioObjectPropertyOwner ||
                   inAddress->mSelector == kAudioObjectPropertyName ||
                   inAddress->mSelector == kAudioStreamPropertyIsActive ||
                   inAddress->mSelector == kAudioStreamPropertyDirection ||
                   inAddress->mSelector == kAudioStreamPropertyTerminalType ||
                   inAddress->mSelector == kAudioStreamPropertyStartingChannel ||
                   inAddress->mSelector == kAudioStreamPropertyLatency ||
                   inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
                   inAddress->mSelector == kAudioStreamPropertyAvailableVirtualFormats ||
                   inAddress->mSelector == kAudioStreamPropertyPhysicalFormat ||
                   inAddress->mSelector == kAudioStreamPropertyAvailablePhysicalFormats;

        default:
            return false;
    }
}

static OSStatus MixedAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inObjectID,
                                              pid_t inClientProcessID,
                                              const AudioObjectPropertyAddress *inAddress,
                                              Boolean *outIsSettable)
{
    (void)inDriver;
    (void)inObjectID;
    (void)inClientProcessID;
    (void)inAddress;
    if (outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    *outIsSettable = false;
    return noErr;
}

static OSStatus MixedAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inObjectID,
                                               pid_t inClientProcessID,
                                               const AudioObjectPropertyAddress *inAddress,
                                               UInt32 inQualifierDataSize,
                                               const void *inQualifierData,
                                               UInt32 *outDataSize)
{
    (void)inDriver;
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;
    if (outDataSize == NULL || inAddress == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!MixedAudio_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyModelName:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioObjectPropertyOwnedObjects:
            if (inObjectID == kMixedAudioObjectID_Device) {
                *outDataSize = sizeof(AudioObjectID);
            } else if (inObjectID == kAudioObjectPlugInObject) {
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return noErr;

        case kAudioDevicePropertyStreams:
            if (inObjectID == kAudioObjectPlugInObject || is_input_property(inAddress) ||
                (inObjectID == kMixedAudioObjectID_Device && is_global_property(inAddress))) {
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            return noErr;

        case kAudioPlugInPropertyBoxList:
            *outDataSize = 0;
            return noErr;

        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            return noErr;

        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return noErr;

        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            return noErr;

        case kAudioDevicePropertyStreamConfiguration:
            *outDataSize = stream_configuration_size(is_output_property(inAddress) ? 0 : 1);
            return noErr;

        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange);
            return noErr;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = sizeof(AudioStreamRangedDescription);
            return noErr;

        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            return noErr;

        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyOwner:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceIsRunningSomewhere:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kMCAAudioDevicePropertyDriverCompatibilityVersion:
        case kMCAAudioDevicePropertySharedMemoryABIVersion:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
            *outDataSize = sizeof(UInt32);
            return noErr;

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus MixedAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress *inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void *inQualifierData,
                                           UInt32 inDataSize,
                                           UInt32 *outDataSize,
                                           void *outData)
{
    (void)inQualifierDataSize;
    (void)inQualifierData;
    if (outDataSize == NULL || outData == NULL || inAddress == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!MixedAudio_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    UInt32 value = 0;
    Float64 sample_rate = MIXED_AUDIO_OUTPUT_SAMPLE_RATE;
    AudioObjectID object_id = 0;
    AudioStreamBasicDescription format = stream_description();
    AudioValueRange sample_rate_range = {
        .mMinimum = MIXED_AUDIO_OUTPUT_SAMPLE_RATE,
        .mMaximum = MIXED_AUDIO_OUTPUT_SAMPLE_RATE
    };
    AudioStreamRangedDescription ranged_format = {
        .mFormat = format,
        .mSampleRateRange = sample_rate_range
    };

    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyClass:
                    value = kAudioPlugInClassID;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioObjectPropertyBaseClass:
                    value = kAudioObjectClassID;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioObjectPropertyOwner:
                    object_id = kAudioObjectUnknown;
                    return write_data(sizeof(object_id), inDataSize, outDataSize, outData, &object_id);
                case kAudioObjectPropertyName:
                    return write_cfstring(inDataSize, outDataSize, outData, CFSTR("MixedCaptureAudio"));
                case kAudioObjectPropertyManufacturer:
                    return write_cfstring(inDataSize, outDataSize, outData, CFSTR("Minami"));
                case kAudioObjectPropertyOwnedObjects:
                    object_id = kMixedAudioObjectID_Device;
                    return write_data(sizeof(object_id), inDataSize, outDataSize, outData, &object_id);
                case kAudioPlugInPropertyBoxList:
                    *outDataSize = 0;
                    return noErr;
                case kAudioPlugInPropertyTranslateUIDToBox:
                    object_id = kAudioObjectUnknown;
                    return write_data(sizeof(object_id), inDataSize, outDataSize, outData, &object_id);
                case kAudioPlugInPropertyDeviceList:
                    object_id = kMixedAudioObjectID_Device;
                    return write_data(sizeof(object_id), inDataSize, outDataSize, outData, &object_id);
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) {
                        *outDataSize = 0;
                        return kAudioHardwareBadPropertySizeError;
                    }
                    object_id = kAudioObjectUnknown;
                    if (*((const CFStringRef *)inQualifierData) != NULL &&
                        CFStringCompare(*((const CFStringRef *)inQualifierData),
                                        CFSTR("com.minamiktr.mca.device.MixedCaptureAudio"),
                                        0) == kCFCompareEqualTo) {
                        object_id = kMixedAudioObjectID_Device;
                    }
                    return write_data(sizeof(object_id), inDataSize, outDataSize, outData, &object_id);
                case kAudioPlugInPropertyResourceBundle:
                    return write_cfstring(inDataSize, outDataSize, outData, CFSTR(""));
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kMixedAudioObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyClass:
                    value = kAudioDeviceClassID;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioObjectPropertyBaseClass:
                    value = kAudioObjectClassID;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioObjectPropertyOwner:
                    object_id = kAudioObjectPlugInObject;
                    return write_data(sizeof(object_id), inDataSize, outDataSize, outData, &object_id);
                case kAudioObjectPropertyName:
                    return write_cfstring(inDataSize, outDataSize, outData, CFSTR("Mixed Capture Audio"));
                case kAudioObjectPropertyManufacturer:
                    return write_cfstring(inDataSize, outDataSize, outData, CFSTR("Minami"));
                case kAudioObjectPropertyModelName:
                    return write_cfstring(inDataSize, outDataSize, outData, CFSTR("Mixed Capture Audio"));
                case kAudioDevicePropertyDeviceUID:
                    return write_cfstring(inDataSize, outDataSize, outData,
                                          CFSTR("com.minamiktr.mca.device.MixedCaptureAudio"));
                case kAudioDevicePropertyModelUID:
                    return write_cfstring(inDataSize, outDataSize, outData, CFSTR(MCA_DRIVER_MODEL_UID));
                case kAudioDevicePropertyTransportType:
                    value = kAudioDeviceTransportTypeVirtual;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioObjectPropertyOwnedObjects:
                    object_id = kMixedAudioObjectID_InputStream;
                    return write_data(sizeof(object_id), inDataSize, outDataSize, outData, &object_id);
                case kAudioDevicePropertyRelatedDevices:
                    object_id = kMixedAudioObjectID_Device;
                    return write_data(sizeof(object_id), inDataSize, outDataSize, outData, &object_id);
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyIsHidden:
                    value = 0;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioDevicePropertyDeviceIsAlive:
                    value = 1;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceIsRunningSomewhere:
                    value = gActiveIOClientCount > 0 ? 1 : 0;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                    value = is_input_property(inAddress) ? 1 : 0;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertySafetyOffset:
                    value = 0;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioDevicePropertyLatency:
                    value = MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioDevicePropertyBufferFrameSize:
                    value = kMixedAudioDefaultBufferFrameSize;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    value = kMixedAudioZeroTimeStampPeriod;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kMCAAudioDevicePropertyDriverCompatibilityVersion:
                    value = MCA_DRIVER_COMPATIBILITY_VERSION;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kMCAAudioDevicePropertySharedMemoryABIVersion:
                    value = MCA_SHARED_MEMORY_ABI_VERSION;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioDevicePropertyNominalSampleRate:
                    return write_data(sizeof(sample_rate), inDataSize, outDataSize, outData, &sample_rate);
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    return write_data(sizeof(sample_rate_range), inDataSize, outDataSize, outData,
                                      &sample_rate_range);
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0;
                    return noErr;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    if (inDataSize < 2 * sizeof(UInt32)) {
                        *outDataSize = 0;
                        return kAudioHardwareBadPropertySizeError;
                    }
                    ((UInt32 *)outData)[0] = 1;
                    ((UInt32 *)outData)[1] = 2;
                    *outDataSize = 2 * sizeof(UInt32);
                    return noErr;
                case kAudioDevicePropertyStreams:
                    if (is_output_property(inAddress)) {
                        *outDataSize = 0;
                        return noErr;
                    }
                    object_id = kMixedAudioObjectID_InputStream;
                    return write_data(sizeof(object_id), inDataSize, outDataSize, outData, &object_id);
                case kAudioDevicePropertyStreamConfiguration:
                    if (inDataSize < stream_configuration_size(is_output_property(inAddress) ? 0 : 1)) {
                        *outDataSize = 0;
                        return kAudioHardwareBadPropertySizeError;
                    }
                    write_stream_configuration((AudioBufferList *)outData, is_output_property(inAddress) ? 0 : 1);
                    *outDataSize = stream_configuration_size(is_output_property(inAddress) ? 0 : 1);
                    return noErr;
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        case kMixedAudioObjectID_InputStream:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyClass:
                    value = kAudioStreamClassID;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioObjectPropertyBaseClass:
                    value = kAudioObjectClassID;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioObjectPropertyOwner:
                    object_id = kMixedAudioObjectID_Device;
                    return write_data(sizeof(object_id), inDataSize, outDataSize, outData, &object_id);
                case kAudioObjectPropertyName:
                    return write_cfstring(inDataSize, outDataSize, outData, CFSTR("Mixed Capture Audio Input"));
                case kAudioStreamPropertyIsActive:
                    value = 1;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioStreamPropertyDirection:
                    value = 1;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioStreamPropertyTerminalType:
                    value = kAudioStreamTerminalTypeMicrophone;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioStreamPropertyStartingChannel:
                    value = 1;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioStreamPropertyLatency:
                    value = 0;
                    return write_data(sizeof(value), inDataSize, outDataSize, outData, &value);
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    return write_data(sizeof(format), inDataSize, outDataSize, outData, &format);
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return write_data(sizeof(ranged_format), inDataSize, outDataSize, outData, &ranged_format);
                default:
                    return kAudioHardwareUnknownPropertyError;
            }

        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus MixedAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress *inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void *inQualifierData,
                                           UInt32 inDataSize,
                                           const void *inData)
{
    (void)inDriver;
    (void)inObjectID;
    (void)inClientProcessID;
    (void)inAddress;
    (void)inQualifierDataSize;
    (void)inQualifierData;
    (void)inDataSize;
    (void)inData;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MixedAudio_StartIO(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inDeviceObjectID,
                                   UInt32 inClientID)
{
    (void)inDriver;
    (void)inClientID;
    if (inDeviceObjectID != kMixedAudioObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    mixed_audio_shm_reader_status_t reader_status =
        mixed_audio_shm_reader_reopen_if_changed(&gSharedMemoryReader, MIXED_AUDIO_SHM_NAME);
    os_log(OS_LOG_DEFAULT,
           "MixedCaptureAudio: shared memory reader start status=%{public}s errno=%d",
           mixed_audio_shm_reader_status_string(reader_status),
           gSharedMemoryReader.last_errno);
    gActiveIOClientCount++;
    return noErr;
}

static OSStatus MixedAudio_StopIO(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inDeviceObjectID,
                                  UInt32 inClientID)
{
    (void)inDriver;
    (void)inClientID;
    if (inDeviceObjectID != kMixedAudioObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    if (gActiveIOClientCount > 0) {
        gActiveIOClientCount--;
    }
    return noErr;
}

static OSStatus MixedAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt32 inClientID,
                                            Float64 *outSampleTime,
                                            UInt64 *outHostTime,
                                            UInt64 *outSeed)
{
    (void)inDriver;
    (void)inClientID;
    if (inDeviceObjectID != kMixedAudioObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    UInt64 now = mach_absolute_time();
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    UInt64 elapsed = now > gStartHostTime ? now - gStartHostTime : 0;
    Float64 elapsed_nanos = (Float64)elapsed * (Float64)timebase.numer / (Float64)timebase.denom;
    *outSampleTime = elapsed_nanos * ((Float64)MIXED_AUDIO_OUTPUT_SAMPLE_RATE / 1000000000.0);
    *outHostTime = now;
    *outSeed = 1;
    return noErr;
}

static OSStatus MixedAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID inDeviceObjectID,
                                             UInt32 inClientID,
                                             UInt32 inOperationID,
                                             Boolean *outWillDo,
                                             Boolean *outWillDoInPlace)
{
    (void)inDriver;
    (void)inClientID;
    if (inDeviceObjectID != kMixedAudioObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    if (outWillDo == NULL || outWillDoInPlace == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    *outWillDo = inOperationID == kAudioServerPlugInIOOperationReadInput;
    *outWillDoInPlace = *outWillDo;
    return noErr;
}

static OSStatus MixedAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt32 inClientID,
                                            UInt32 inOperationID,
                                            UInt32 inIOBufferFrameSize,
                                            const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return inDeviceObjectID == kMixedAudioObjectID_Device ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus MixedAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID,
                                         AudioObjectID inStreamObjectID,
                                         UInt32 inClientID,
                                         UInt32 inOperationID,
                                         UInt32 inIOBufferFrameSize,
                                         const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                         void *ioMainBuffer,
                                         void *ioSecondaryBuffer)
{
    (void)inDriver;
    (void)inClientID;
    (void)inIOCycleInfo;
    (void)ioSecondaryBuffer;
    if (inDeviceObjectID != kMixedAudioObjectID_Device ||
        inStreamObjectID != kMixedAudioObjectID_InputStream) {
        return kAudioHardwareBadObjectError;
    }
    if (inOperationID != kAudioServerPlugInIOOperationReadInput) {
        return kAudioHardwareUnsupportedOperationError;
    }

    read_shared_memory_audio(ioMainBuffer, inIOBufferFrameSize, inIOCycleInfo);
    return noErr;
}

static OSStatus MixedAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID,
                                          UInt32 inOperationID,
                                          UInt32 inIOBufferFrameSize,
                                          const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return inDeviceObjectID == kMixedAudioObjectID_Device ? noErr : kAudioHardwareBadObjectError;
}

__attribute__((visibility("default")))
void *MixedCaptureAudio_Create(CFAllocatorRef allocator, CFUUIDRef requested_type_uuid)
{
    (void)allocator;

    if (requested_type_uuid == NULL ||
        CFEqual(requested_type_uuid, kAudioServerPlugInDriverInterfaceUUID) ||
        CFEqual(requested_type_uuid, kAudioServerPlugInTypeUUID)) {
        return &gDriverInterfacePtr;
    }

    return NULL;
}
