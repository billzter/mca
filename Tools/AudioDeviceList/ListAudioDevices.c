#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

#include "MixedCaptureAudioCompatibility.h"

static void print_cfstring(CFStringRef value)
{
    char buffer[512];
    if (value != NULL && CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        printf("%s", buffer);
        return;
    }
    printf("<unknown>");
}

static UInt32 input_channel_count(AudioObjectID device_id)
{
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyStreamConfiguration,
        .mScope = kAudioDevicePropertyScopeInput,
        .mElement = kAudioObjectPropertyElementMain
    };

    UInt32 data_size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device_id, &address, 0, NULL, &data_size);
    if (status != noErr || data_size == 0) {
        return 0;
    }

    AudioBufferList *buffer_list = (AudioBufferList *)calloc(1, data_size);
    if (buffer_list == NULL) {
        return 0;
    }

    status = AudioObjectGetPropertyData(device_id, &address, 0, NULL, &data_size, buffer_list);
    if (status != noErr) {
        free(buffer_list);
        return 0;
    }

    UInt32 channels = 0;
    for (UInt32 i = 0; i < buffer_list->mNumberBuffers; i++) {
        channels += buffer_list->mBuffers[i].mNumberChannels;
    }

    free(buffer_list);
    return channels;
}

static CFStringRef copy_string_property(AudioObjectID object_id, AudioObjectPropertySelector selector)
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

static int copy_uint32_property(AudioObjectID object_id,
                                AudioObjectPropertySelector selector,
                                UInt32 *out_value)
{
    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    UInt32 value = 0;
    UInt32 data_size = sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(object_id, &address, 0, NULL, &data_size, &value);
    if (status != noErr || data_size != sizeof(value)) {
        return 0;
    }
    *out_value = value;
    return 1;
}

static int is_mixed_capture_uid(CFStringRef uid)
{
    return uid != NULL &&
           CFStringCompare(uid, CFSTR("com.minamiktr.mca.device.MixedCaptureAudio"), 0) == kCFCompareEqualTo;
}

int main(void)
{
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };

    UInt32 data_size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &data_size);
    if (status != noErr) {
        fprintf(stderr, "failed to get device list size: %d\n", (int)status);
        return 1;
    }

    UInt32 device_count = data_size / sizeof(AudioObjectID);
    AudioObjectID *devices = (AudioObjectID *)calloc(device_count, sizeof(AudioObjectID));
    if (devices == NULL) {
        fprintf(stderr, "failed to allocate device list\n");
        return 1;
    }

    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &data_size, devices);
    if (status != noErr) {
        fprintf(stderr, "failed to get device list: %d\n", (int)status);
        free(devices);
        return 1;
    }

    for (UInt32 i = 0; i < device_count; i++) {
        UInt32 channels = input_channel_count(devices[i]);
        if (channels == 0) {
            continue;
        }

        CFStringRef name = copy_string_property(devices[i], kAudioObjectPropertyName);
        CFStringRef uid = copy_string_property(devices[i], kAudioDevicePropertyDeviceUID);
        printf("%u input channel(s) | ", channels);
        print_cfstring(name);
        printf(" | ");
        print_cfstring(uid);
        if (is_mixed_capture_uid(uid)) {
            CFStringRef model_uid = copy_string_property(devices[i], kAudioDevicePropertyModelUID);
            printf(" | model_uid=");
            print_cfstring(model_uid);
            if (model_uid != NULL) {
                CFRelease(model_uid);
            }

            UInt32 driver_compatibility = 0;
            UInt32 shared_memory_abi = 0;
            printf(" | driver_compat=");
            if (copy_uint32_property(devices[i],
                                     kMCAAudioDevicePropertyDriverCompatibilityVersion,
                                     &driver_compatibility)) {
                printf("%u", driver_compatibility);
            } else {
                printf("<missing>");
            }
            printf(" | shm_abi=");
            if (copy_uint32_property(devices[i],
                                     kMCAAudioDevicePropertySharedMemoryABIVersion,
                                     &shared_memory_abi)) {
                printf("%u", shared_memory_abi);
            } else {
                printf("<missing>");
            }
        }
        printf("\n");

        if (name != NULL) {
            CFRelease(name);
        }
        if (uid != NULL) {
            CFRelease(uid);
        }
    }

    free(devices);
    return 0;
}
