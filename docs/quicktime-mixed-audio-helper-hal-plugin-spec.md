# QuickTime MixedCaptureAudio HAL Plug-In Spec

## Summary

`MixedCaptureAudio.driver` is a C AudioServerPlugIn bundle that exposes one virtual input device named `Mixed Capture Audio`. It is a non-blocking shared-memory reader. It does not capture, mix, prompt, call Swift, call the Rust mixer, or own app policy.

The plug-in makes QuickTime/Screenshot see one microphone-like input. The app-owned Rust mixer writes the final mixed stream to POSIX shared memory; the HAL plug-in reads that stream and gives it to Core Audio.

Hard rule:

```text
If anything is missing, stale, invalid, unsupported, or late, return silence.
```

ABI constants:

```text
MIXED_AUDIO_ABI_VERSION = 1
MIXED_AUDIO_OUTPUT_SAMPLE_RATE = 48000
MIXED_AUDIO_OUTPUT_CHANNEL_COUNT = 2
MIXED_AUDIO_TARGET_SHARED_FILL_MS = 50
MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES = 2400
```

The target shared-ring fill is a fixed app/HAL ABI contract for v1. The HAL uses it for latency reporting even when the app is stopped and shared memory is unavailable.

## Product And Bundle

Install path:

```text
/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver
```

Bundle shape:

```text
MixedCaptureAudio.driver/
  Contents/
    Info.plist
    MacOS/
      MixedCaptureAudio
```

Target:

- Xcode C bundle target.
- Product extension: `.driver`.
- Links `CoreAudio.framework`.
- Includes `HALPlugin/Include/MixedAudioSharedMemory.h`.
- Does not link Swift app code or the Rust mixer static library.

Bundle identity placeholders:

```text
Bundle display name: Mixed Capture Audio
Bundle identifier: com.minamiktr.mca.driver
Executable: MixedCaptureAudio
Manufacturer: Minami
```

Detailed plist keys are documented in `/tmp/quicktime-mixed-audio-helper-plist-requirements.md`.

## Factory And Interface

Core Audio discovers the plug-in through bundle metadata and calls the plug-in factory. The factory returns an `AudioServerPlugInDriverInterface`, a C function-pointer table used by Core Audio.

Required high-level shape:

```c
void *MixedCaptureAudio_Create(CFAllocatorRef allocator, CFUUIDRef requested_type_uuid);
```

The factory should:

- Validate that Core Audio requested an audio server plug-in driver interface.
- Return a pointer to the singleton `AudioServerPlugInDriverInterface`.
- Return `NULL` for unsupported requested types.

The driver interface must implement these callbacks:

- `QueryInterface`
- `AddRef`
- `Release`
- `Initialize`
- `CreateDevice`
- `DestroyDevice`
- `AddDeviceClient`
- `RemoveDeviceClient`
- `PerformDeviceConfigurationChange`
- `AbortDeviceConfigurationChange`
- `HasProperty`
- `IsPropertySettable`
- `GetPropertyDataSize`
- `GetPropertyData`
- `SetPropertyData`
- `StartIO`
- `StopIO`
- `GetZeroTimeStamp`
- `WillDoIOOperation`
- `BeginIOOperation`
- `DoIOOperation`
- `EndIOOperation`

Callbacks that are not meaningful for the v1 virtual input device should return the appropriate Core Audio unsupported/no-op result, not crash or block.

## Object Model

Use a fixed, tiny object model.

```text
Plug-in object
  Object ID: kAudioObjectPlugInObject

Device object
  Object ID: 2
  Name: Mixed Capture Audio
  Direction: input-only

Input stream object
  Object ID: 3
  Parent: Device object
  Direction: input
  Format: 48 kHz stereo Float32 interleaved
```

Recommended constants:

```c
enum {
    kMixedAudioObjectID_Device = 2,
    kMixedAudioObjectID_InputStream = 3
};
```

Do not expose output streams in v1.

Do not expose source-specific objects for mic, system audio, or future per-app audio. The HAL device receives only the final mixed stream.

## Advertised Audio Format

V1 supports exactly one native stream format:

```text
sample rate: 48000
channels: 2
sample type: Float32
layout: interleaved stereo
direction: input
```

The app/Rust mixer must produce this format before writing shared memory.

The HAL plug-in should avoid format conversion in v1. If Core Audio requests a different format, either report unsupported or expose only the supported format so Core Audio negotiates/uses the native stream correctly. Source format conversion, drift handling, and rate matching belong to the app/Rust side before frames enter shared memory.

## Required Property Behavior

The plug-in must answer Core Audio property queries for the plug-in object, device object, and input stream object.

### Plug-In Object

Must expose:

- Owned devices: one device object ID.
- Manufacturer/name metadata where applicable.

Behavior:

- The plug-in always owns one virtual device.
- The device exists whether or not the app is running.
- App availability affects audio content, not device existence.

### Device Object

Must expose:

- Object class.
- Owner.
- Name: `Mixed Capture Audio`.
- Manufacturer.
- UID.
- Model UID.
- Alive/running state.
- Input streams: one input stream object ID.
- Output streams: empty.
- Nominal sample rate: 48000.
- Available nominal sample rates: 48000 only.
- Input/device latency that includes intrinsic HAL latency plus the fixed target shared-ring fill ABI constant.
- Device configuration-related properties required by Core Audio.

Behavior:

- Device is input-only.
- Device should report alive as long as the plug-in is loaded.
- Running reflects Core Audio IO lifecycle state, not whether the app is actively producing audio.
- If the app is not producing audio, the device remains available and returns silence.
- Reported latency must not hide the fixed app/Rust/HAL target shared-ring fill; otherwise QuickTime may record audio late relative to video.

### Input Stream Object

Must expose:

- Object class.
- Owner device.
- Direction: input.
- Starting channel: 1.
- Latency: 0 or a conservative fixed value.
- Virtual format: 48 kHz stereo Float32.
- Physical format: 48 kHz stereo Float32.
- Available virtual/physical formats: 48 kHz stereo Float32 only.

Behavior:

- Stream is always present.
- Stream never reports mic/system source details.

## IO Lifecycle

### `Initialize`

Purpose:

- Store host reference if needed.
- Initialize static driver state.
- Initialize mutexes/atomics used outside IO path.
- Do not open mic, create taps, start mixing, or create shared memory.

Result:

- Return success if static initialization succeeds.

### `AddDeviceClient`

Purpose:

- Track Core Audio client IDs if needed.

Behavior:

- Add the client to non-real-time state.
- Do not open shared memory here unless convenient and non-blocking.

### `RemoveDeviceClient`

Purpose:

- Remove client tracking.

Behavior:

- If no clients remain, keep device alive.
- Do not unload the plug-in.

### `StartIO`

Purpose:

- Mark the device running for the given client.
- Prepare the shared-memory reader.

Behavior:

- Increment active IO client count.
- Attempt to open/map shared memory if not already mapped.
- Validate header if mapped.
- Set running state true if at least one client is active.
- Return success even if shared memory is unavailable; unavailable data becomes silence.

Do not:

- Block waiting for the app.
- Launch the app.
- Prompt the user.
- Create process taps.
- Capture mic audio.

### `StopIO`

Purpose:

- Mark client IO stopped.

Behavior:

- Decrement active IO client count.
- Set running state false when active count reaches zero.
- Optionally keep shared memory mapped for faster restart.
- Do not destroy the virtual device.

### `WillDoIOOperation`

Purpose:

- Tell Core Audio which IO operations the plug-in supports.

V1 behavior:

- Support the input read operation used to transfer native input data from the device into Core Audio’s buffer.
- Do not support output/write operations because this is an input-only device.
- Prefer in-place behavior when Core Audio expects it for the input read operation.

### `BeginIOOperation`

Purpose:

- Per-cycle bookkeeping.

Behavior:

- Keep it minimal.
- No allocation, blocking, logging, XPC, Swift, Objective-C, or file IO.

### `DoIOOperation`

Purpose:

- Fill Core Audio’s input buffer for the requested cycle.

Behavior for input read:

```text
1. Validate shared-memory mapping/header/format/heartbeat/generation.
2. If invalid or stale, fill requested frames with silence and return success.
3. Compute available frames from write/read indices.
4. Copy min(available, requested) frames into Core Audio buffer.
5. Silence-fill the remainder.
6. Advance read index only for frames actually copied.
7. Increment underrun counter if any silence-fill was needed due to insufficient data.
8. Return success.
```

Do not:

- Wait for more frames.
- Allocate.
- Lock a mutex.
- Call app code.
- Call XPC/Mach messaging.
- Perform format conversion beyond simple copy/silence.

### `EndIOOperation`

Purpose:

- End-of-cycle bookkeeping.

Behavior:

- No-op unless a future non-real-time-safe reason appears.

### `GetZeroTimeStamp`

Purpose:

- Provide timing information Core Audio expects from devices.

V1 behavior:

- Anchor the device timeline to host time, not only to “frames served.”
- Keep a stable relationship between sample time and `mach_absolute_time`/Core Audio host time.
- Report a rate scalar of `1.0` unless prototype evidence requires otherwise.
- Keep sample time monotonic and consistent with the advertised 48 kHz nominal rate.
- Report latency conservatively enough that QuickTime A/V sync remains acceptable.
- Include the fixed V1 target shared-ring fill ABI constant in the latency reported to Core Audio clients.
- Do not derive timing from app producer heartbeat or shared-memory availability.
- If the app is stopped or shared memory is unavailable, the HAL timeline still advances while outputting silence.

Prototype requirements:

- Compare the implementation against Apple sample-driver/NullAudio timing behavior.
- Query and verify reported latency while the app is stopped and no shared memory exists.
- Test A/V sync at the fixed V1 target-fill constant.
- Measure QuickTime screen-recording A/V sync with the virtual input selected.
- Record the observed device latency and update the final HAL constants before freezing the V1 ABI if prototype data requires it.

Latency rule:

```text
reported_input_latency_frames =
    intrinsic_hal_latency_frames
  + MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES
  + measured_safety_latency_frames
```

Actual shared-ring fill may vary around `MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES`. The residual difference between actual fill and the fixed reported target is residual A/V sync error. The HAL still reports the fixed ABI constant; the app/Rust control loop is responsible for keeping actual fill within the release sync-error budget.

The shared-memory header may mirror `target_shared_fill_frames` for diagnostics and compatibility validation, but it is not the HAL source of truth for latency. If the target fill changes, bump the app/HAL ABI version and shared-memory object name, then ship matching app and driver updates.

## Shared-Memory Reader

Implement reader code in:

```text
HALPlugin/Sources/MixedAudioSharedMemoryReader.c
HALPlugin/Include/MixedAudioSharedMemory.h
```

Reader responsibilities:

- Open shared memory by agreed object name.
- Map the header and audio ring.
- Validate magic/version/format/capacity.
- Check heartbeat freshness.
- Detect generation changes.
- Copy available frames.
- Silence-fill missing frames.
- Advance read index safely.
- Acquire `write_frame_index` before reading frames.
- Store read progress atomically after consuming frames.
- Return status suitable for diagnostics and tests.

Reader API shape:

```c
typedef struct MixedAudioSharedMemoryReader MixedAudioSharedMemoryReader;

bool MixedAudioSharedMemoryReader_Open(MixedAudioSharedMemoryReader *reader);
void MixedAudioSharedMemoryReader_Close(MixedAudioSharedMemoryReader *reader);

uint32_t MixedAudioSharedMemoryReader_Read(
    MixedAudioSharedMemoryReader *reader,
    float *out_interleaved_stereo,
    uint32_t requested_frames
);

void MixedAudioSharedMemoryReader_FillSilence(
    float *out_interleaved_stereo,
    uint32_t frame_count
);
```

`Read` returns the number of real frames copied. The caller silence-fills `requested_frames - copied_frames`.

## Real-Time Safety Rules

Inside IO-path callbacks:

- No heap allocation.
- No mutex waits.
- No Objective-C or Swift calls.
- No Rust mixer calls.
- No XPC/Mach messaging.
- No synchronous logging.
- No file IO.
- No client HAL API calls.
- No waiting for shared memory or producer heartbeat.
- No timing queries that can block.

Allowed:

- Atomic loads/stores.
- Pointer validation already backed by mapped memory.
- Bounded memory copies.
- Silence fill.
- Counter increments.

## Logging And Diagnostics

The HAL plug-in should log minimally and never from the hot IO path.

Allowed non-IO diagnostics:

- Driver loaded.
- Shared memory open failed.
- Header validation failed.
- Unsupported property queried during development.

Diagnostics visible to the app should come primarily from shared-memory counters and app-side state, not plug-in callbacks.

The HAL plug-in must not log audio samples or write diagnostic files from the IO path. Diagnostics, preferences, logging, and privacy rules are documented in `/tmp/quicktime-mixed-audio-helper-diagnostics-preferences-and-privacy.md`.

## Install, Reload, And Uninstall

Development install:

```text
sudo cp -R MixedCaptureAudio.driver /Library/Audio/Plug-Ins/HAL/
```

Development uninstall:

```text
sudo rm -rf /Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver
```

Release driver updates:

```text
signed/notarized package installer
```

V1 should not use a privileged background helper to replace the HAL driver. The app should stop capture, guide the user through the installer package, then re-check driver version, shared-memory ABI compatibility, target shared-fill constant compatibility, and Core Audio device visibility.

Development reload options:

- Prefer logout/restart for user-facing guidance.
- For developer-only scripts, document any Core Audio reload command separately and require explicit confirmation.
- Do not make the app automatically kill/restart Core Audio in v1.

Detailed update policy is documented in `/tmp/quicktime-mixed-audio-helper-update-and-installation-strategy.md`.

The confirmation matrix for install permissions and Core Audio reload behavior is documented in `/tmp/quicktime-mixed-audio-helper-remaining-confirmations.md`.

## Test Strategy

### Unit Tests For Shared-Memory Reader

Use a command-line C test harness.

Cases:

- Missing shared memory returns zero real frames and silence-fill path.
- Invalid magic returns zero real frames.
- Invalid version returns zero real frames.
- Unsupported sample rate/channel count returns zero real frames.
- Known ramp frames are copied exactly.
- Partial availability copies real frames and silence-fills the rest.
- Generation change forces resync.
- Stale heartbeat returns zero real frames.
- Overrun state keeps newest frames and increments counters.
- C/Rust shared-memory header size and offsets match.
- Header atomics are lock-free on supported architectures.
- Acquire/release ordering prevents reading unpublished frames.

### HAL Load Tests

After installation/reload:

- Core Audio enumerates `Mixed Capture Audio`.
- Device has one input stream.
- Device has zero output streams.
- Sample rate reports 48000.
- Stream format reports stereo Float32.
- Device remains visible when the app is not running.
- `GetZeroTimeStamp` reports host-time-anchored, monotonic timing.
- Reported latency includes the fixed target shared-ring fill ABI constant.
- Reported latency and timestamp behavior keep QuickTime A/V sync acceptable in manual tests.

### QuickTime Tests

- QuickTime screen recording microphone menu shows `Mixed Capture Audio`.
- With app stopped, recording contains silence rather than noise/crash.
- With app running and shared memory receiving ramp/sine, recording captures expected audio.
- With app running and real mixer active, recording captures system audio plus mic.
- Stopping app mid-recording results in silence fallback.
- Restarting app mid-recording resumes audio after generation resync.

## Non-Goals

V1 HAL plug-in does not:

- Expose output streams.
- Expose multiple devices.
- Expose source-specific streams.
- Handle per-app routing.
- Capture audio.
- Mix audio.
- Convert arbitrary sample formats.
- Launch or control the app.
- Provide a rich plug-in-to-app control channel.

## References

- Apple Audio Server Driver Plug-in guide: [Creating an audio server driver plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- Apple `AudioServerPlugInDriverInterface`: [AudioServerPlugInDriverInterface](https://developer.apple.com/documentation/coreaudio/audioserverplugindriverinterface)
- Apple `StartIO`: [StartIO](https://developer.apple.com/documentation/coreaudio/audioserverplugindriverinterface/startio)
- Apple QA1811: [AudioServerPlugIns and client HAL API restrictions](https://developer.apple.com/library/archive/qa/qa1811/_index.html)
