#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "MixedCaptureAudioCompatibility.h"
#include "MixedAudioSharedMemory.h"

enum {
    kMixedAudioObjectID_Device = 2,
    kMixedAudioObjectID_InputStream = 3
};

typedef void *(*MixedCaptureAudioCreateFn)(CFAllocatorRef allocator, CFUUIDRef requested_type_uuid);

static void fail(const char *message)
{
    fprintf(stderr, "HAL driver smoke test failed: %s\n", message);
    exit(1);
}

static void expect_status(OSStatus status, const char *message)
{
    if (status != noErr) {
        fprintf(stderr, "HAL driver smoke test failed: %s (%d)\n", message, (int)status);
        exit(1);
    }
}

static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                          AudioObjectPropertyScope scope)
{
    AudioObjectPropertyAddress result = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain
    };
    return result;
}

static void expect_cfstring(AudioServerPlugInDriverInterface *driver,
                            AudioServerPlugInDriverRef driver_ref,
                            AudioObjectID object_id,
                            AudioObjectPropertySelector selector,
                            CFStringRef expected)
{
    AudioObjectPropertyAddress property = address(selector, kAudioObjectPropertyScopeGlobal);
    UInt32 data_size = 0;
    expect_status(driver->GetPropertyDataSize(driver_ref, object_id, 0, &property, 0, NULL, &data_size),
                  "string property size");
    if (data_size != sizeof(CFStringRef)) {
        fail("unexpected CFString property size");
    }

    CFStringRef value = NULL;
    UInt32 used_size = 0;
    expect_status(driver->GetPropertyData(driver_ref, object_id, 0, &property, 0, NULL,
                                          sizeof(value), &used_size, &value),
                  "string property data");
    if (used_size != sizeof(CFStringRef) || value == NULL) {
        fail("missing CFString property value");
    }
    if (CFStringCompare(value, expected, 0) != kCFCompareEqualTo) {
        fail("unexpected CFString property value");
    }
    CFRelease(value);
}

static void expect_uint32(AudioServerPlugInDriverInterface *driver,
                          AudioServerPlugInDriverRef driver_ref,
                          AudioObjectID object_id,
                          AudioObjectPropertySelector selector,
                          AudioObjectPropertyScope scope,
                          UInt32 expected)
{
    AudioObjectPropertyAddress property = address(selector, scope);
    UInt32 data_size = 0;
    expect_status(driver->GetPropertyDataSize(driver_ref, object_id, 0, &property, 0, NULL, &data_size),
                  "UInt32 property size");
    if (data_size != sizeof(UInt32)) {
        fail("unexpected UInt32 property size");
    }

    UInt32 value = 0;
    UInt32 used_size = 0;
    expect_status(driver->GetPropertyData(driver_ref, object_id, 0, &property, 0, NULL,
                                          sizeof(value), &used_size, &value),
                  "UInt32 property data");
    if (used_size != sizeof(UInt32) || value != expected) {
        fail("unexpected UInt32 property value");
    }
}

int main(void)
{
    const char *driver_path = "Build/Debug/MixedCaptureAudio.driver/Contents/MacOS/MixedCaptureAudio";
    void *library = dlopen(driver_path, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }

    MixedCaptureAudioCreateFn create =
        (MixedCaptureAudioCreateFn)dlsym(library, "MixedCaptureAudio_Create");
    if (create == NULL) {
        fail("factory symbol not found");
    }

    void *created = create(kCFAllocatorDefault, kAudioServerPlugInDriverInterfaceUUID);
    if (created == NULL) {
        fail("factory returned NULL");
    }

    AudioServerPlugInDriverInterface **interface_ptr =
        (AudioServerPlugInDriverInterface **)created;
    AudioServerPlugInDriverInterface *driver = *interface_ptr;
    if (driver == NULL) {
        fail("driver interface pointer is NULL");
    }

    if (driver->QueryInterface == NULL ||
        driver->AddRef == NULL ||
        driver->Release == NULL ||
        driver->Initialize == NULL ||
        driver->HasProperty == NULL ||
        driver->GetPropertyDataSize == NULL ||
        driver->GetPropertyData == NULL ||
        driver->WillDoIOOperation == NULL ||
        driver->DoIOOperation == NULL) {
        fail("required callback is NULL");
    }

    AudioServerPlugInDriverRef driver_ref = (AudioServerPlugInDriverRef)interface_ptr;
    AudioServerPlugInHostInterface host = {0};
    expect_status(driver->Initialize(driver_ref, &host), "initialize");

    AudioObjectPropertyAddress owned_devices =
        address(kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal);
    UInt32 data_size = 0;
    expect_status(driver->GetPropertyDataSize(driver_ref, kAudioObjectPlugInObject, 0,
                                              &owned_devices, 0, NULL, &data_size),
                  "owned devices data size");
    if (data_size != sizeof(AudioObjectID)) {
        fail("plug-in should own exactly one device");
    }

    AudioObjectID device_id = 0;
    UInt32 used_size = 0;
    expect_status(driver->GetPropertyData(driver_ref, kAudioObjectPlugInObject, 0,
                                          &owned_devices, 0, NULL,
                                          sizeof(device_id), &used_size, &device_id),
                  "owned devices data");
    if (used_size != sizeof(device_id) || device_id != kMixedAudioObjectID_Device) {
        fail("unexpected device object id");
    }

    AudioObjectPropertyAddress device_list =
        address(kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal);
    data_size = 0;
    expect_status(driver->GetPropertyDataSize(driver_ref, kAudioObjectPlugInObject, 0,
                                              &device_list, 0, NULL, &data_size),
                  "plug-in device list data size");
    if (data_size != sizeof(AudioObjectID)) {
        fail("plug-in device list should contain exactly one device");
    }

    device_id = 0;
    used_size = 0;
    expect_status(driver->GetPropertyData(driver_ref, kAudioObjectPlugInObject, 0,
                                          &device_list, 0, NULL,
                                          sizeof(device_id), &used_size, &device_id),
                  "plug-in device list data");
    if (used_size != sizeof(device_id) || device_id != kMixedAudioObjectID_Device) {
        fail("unexpected plug-in device list object id");
    }

    AudioObjectPropertyAddress translate_uid =
        address(kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    CFStringRef device_uid = CFSTR("com.minamiktr.mca.device.MixedCaptureAudio");
    device_id = 0;
    used_size = 0;
    expect_status(driver->GetPropertyData(driver_ref, kAudioObjectPlugInObject, 0,
                                          &translate_uid, sizeof(device_uid), &device_uid,
                                          sizeof(device_id), &used_size, &device_id),
                  "translate UID to device");
    if (used_size != sizeof(device_id) || device_id != kMixedAudioObjectID_Device) {
        fail("device UID should translate to the mixed capture device");
    }

    expect_cfstring(driver, driver_ref, kMixedAudioObjectID_Device,
                    kAudioObjectPropertyName, CFSTR("Mixed Capture Audio"));
    expect_cfstring(driver, driver_ref, kMixedAudioObjectID_Device,
                    kAudioDevicePropertyDeviceUID, CFSTR("com.minamiktr.mca.device.MixedCaptureAudio"));
    expect_cfstring(driver, driver_ref, kMixedAudioObjectID_Device,
                    kAudioDevicePropertyModelUID, CFSTR(MCA_DRIVER_MODEL_UID));

    AudioObjectPropertyAddress device_owned_objects =
        address(kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal);
    data_size = 0;
    expect_status(driver->GetPropertyDataSize(driver_ref, kMixedAudioObjectID_Device, 0,
                                              &device_owned_objects, 0, NULL, &data_size),
                  "device owned objects data size");
    if (data_size != sizeof(AudioObjectID)) {
        fail("device should own exactly one stream object");
    }

    AudioObjectID owned_object_id = 0;
    used_size = 0;
    expect_status(driver->GetPropertyData(driver_ref, kMixedAudioObjectID_Device, 0,
                                          &device_owned_objects, 0, NULL,
                                          sizeof(owned_object_id), &used_size, &owned_object_id),
                  "device owned objects data");
    if (used_size != sizeof(owned_object_id) || owned_object_id != kMixedAudioObjectID_InputStream) {
        fail("unexpected device owned object id");
    }

    AudioObjectPropertyAddress related_devices =
        address(kAudioDevicePropertyRelatedDevices, kAudioObjectPropertyScopeGlobal);
    data_size = 0;
    expect_status(driver->GetPropertyDataSize(driver_ref, kMixedAudioObjectID_Device, 0,
                                              &related_devices, 0, NULL, &data_size),
                  "related devices data size");
    if (data_size != sizeof(AudioObjectID)) {
        fail("device should report itself as the only related device");
    }

    AudioObjectID related_device_id = 0;
    used_size = 0;
    expect_status(driver->GetPropertyData(driver_ref, kMixedAudioObjectID_Device, 0,
                                          &related_devices, 0, NULL,
                                          sizeof(related_device_id), &used_size, &related_device_id),
                  "related devices data");
    if (used_size != sizeof(related_device_id) || related_device_id != kMixedAudioObjectID_Device) {
        fail("unexpected related device object id");
    }

    expect_uint32(driver, driver_ref, kMixedAudioObjectID_Device,
                  kAudioDevicePropertyClockDomain, kAudioObjectPropertyScopeGlobal, 0);
    expect_uint32(driver, driver_ref, kMixedAudioObjectID_Device,
                  kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, 0);
    expect_uint32(driver, driver_ref, kMixedAudioObjectID_Device,
                  kAudioDevicePropertyZeroTimeStampPeriod, kAudioObjectPropertyScopeGlobal, 16384);
    expect_uint32(driver, driver_ref, kMixedAudioObjectID_Device,
                  kMCAAudioDevicePropertyDriverCompatibilityVersion,
                  kAudioObjectPropertyScopeGlobal,
                  MCA_DRIVER_COMPATIBILITY_VERSION);
    expect_uint32(driver, driver_ref, kMixedAudioObjectID_Device,
                  kMCAAudioDevicePropertySharedMemoryABIVersion,
                  kAudioObjectPropertyScopeGlobal,
                  MCA_SHARED_MEMORY_ABI_VERSION);
    expect_uint32(driver, driver_ref, kMixedAudioObjectID_Device,
                  kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput, 1);
    expect_uint32(driver, driver_ref, kMixedAudioObjectID_Device,
                  kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeInput, 0);
    expect_uint32(driver, driver_ref, kMixedAudioObjectID_Device,
                  kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput,
                  MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES);
    expect_uint32(driver, driver_ref, kMixedAudioObjectID_Device,
                  kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, 0);

    AudioObjectPropertyAddress controls =
        address(kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal);
    data_size = 0;
    expect_status(driver->GetPropertyDataSize(driver_ref, kMixedAudioObjectID_Device, 0,
                                              &controls, 0, NULL, &data_size),
                  "control list data size");
    if (data_size != 0) {
        fail("device should expose no controls");
    }

    AudioObjectPropertyAddress stereo_channels =
        address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeInput);
    UInt32 stereo[2] = {0, 0};
    used_size = 0;
    expect_status(driver->GetPropertyData(driver_ref, kMixedAudioObjectID_Device, 0,
                                          &stereo_channels, 0, NULL,
                                          sizeof(stereo), &used_size, stereo),
                  "preferred stereo channels");
    if (used_size != sizeof(stereo) || stereo[0] != 1 || stereo[1] != 2) {
        fail("unexpected preferred stereo channels");
    }

    AudioObjectPropertyAddress streams =
        address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
    data_size = 0;
    expect_status(driver->GetPropertyDataSize(driver_ref, kMixedAudioObjectID_Device, 0,
                                              &streams, 0, NULL, &data_size),
                  "input streams data size");
    if (data_size != sizeof(AudioObjectID)) {
        fail("device should expose exactly one input stream");
    }

    AudioObjectID stream_id = 0;
    used_size = 0;
    expect_status(driver->GetPropertyData(driver_ref, kMixedAudioObjectID_Device, 0,
                                          &streams, 0, NULL,
                                          sizeof(stream_id), &used_size, &stream_id),
                  "input streams data");
    if (used_size != sizeof(stream_id) || stream_id != kMixedAudioObjectID_InputStream) {
        fail("unexpected input stream object id");
    }

    AudioObjectPropertyAddress sample_rate =
        address(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    Float64 rate = 0;
    used_size = 0;
    expect_status(driver->GetPropertyData(driver_ref, kMixedAudioObjectID_Device, 0,
                                          &sample_rate, 0, NULL,
                                          sizeof(rate), &used_size, &rate),
                  "nominal sample rate");
    if (used_size != sizeof(rate) || fabs(rate - MIXED_AUDIO_OUTPUT_SAMPLE_RATE) > 0.01) {
        fail("unexpected nominal sample rate");
    }

    Boolean will_do = false;
    Boolean will_do_in_place = false;
    expect_status(driver->WillDoIOOperation(driver_ref, kMixedAudioObjectID_Device, 1,
                                            kAudioServerPlugInIOOperationReadInput,
                                            &will_do, &will_do_in_place),
                  "WillDoIOOperation read input");
    if (!will_do || !will_do_in_place) {
        fail("driver should perform read input in place");
    }

    float audio[16];
    for (size_t i = 0; i < sizeof(audio) / sizeof(audio[0]); i++) {
        audio[i] = 123.0f;
    }
    AudioServerPlugInIOCycleInfo cycle_info = {0};
    expect_status(driver->DoIOOperation(driver_ref, kMixedAudioObjectID_Device,
                                        kMixedAudioObjectID_InputStream, 1,
                                        kAudioServerPlugInIOOperationReadInput,
                                        8, &cycle_info, audio, NULL),
                  "DoIOOperation read input");
    for (size_t i = 0; i < sizeof(audio) / sizeof(audio[0]); i++) {
        if (audio[i] != 0.0f) {
            fail("read input should fill silence");
        }
    }

    driver->Release(driver_ref);
    dlclose(library);
    printf("HAL driver smoke test passed\n");
    return 0;
}
