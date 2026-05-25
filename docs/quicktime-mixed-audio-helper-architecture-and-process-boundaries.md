# QuickTime MixedCaptureAudio Architecture And Process Boundaries

## Summary

The app process owns capture, mixing, permissions, UI, diagnostics, and session control. The HAL AudioServerPlugIn is a small virtual-device reader loaded by the Core Audio host. Audio crosses the process boundary through a POSIX shared-memory ring buffer.

Hard rule: the HAL plug-in is a non-blocking shared-memory reader, not a capture engine, mixer, controller, logger, or policy owner.

## Process Model

```text
Swift menu-bar app process
  - owns UI, permissions, preferences, diagnostics
  - creates global system audio process tap
  - opens selected microphone input
  - passes capture buffers into Rust mixer through C ABI
  - creates POSIX shared-memory object
  - writes mixed stereo Float32 frames into shared memory
  - updates heartbeat, generation, and health counters

POSIX shared memory
  - fixed C-compatible header
  - interleaved 48 kHz stereo Float32 ring buffer
  - atomic read/write indices and counters

HAL AudioServerPlugIn loaded by Core Audio host
  - exposes one input device named "Mixed Capture Audio"
  - opens/maps shared memory if available
  - reads frames during IO without blocking
  - returns silence on missing/stale/insufficient data

QuickTime / Screenshot
  - selects "Mixed Capture Audio" as a microphone input
```

## Data Plane

Preferred v1 transport is POSIX shared memory for mixed audio frames. The app is the producer. The HAL plug-in is the consumer.

This transport is not assumed safe until proven. The HAL plug-in runs inside sandboxed `coreaudiod`, so Phase 1 must prove that the plug-in can open and map the app-created shared-memory object on a clean target Mac.

Shared memory contains the final mixed stream, not raw sources. The app captures global system audio and the selected microphone, passes those buffers into the Rust mixer, and the Rust mixer writes the mixed stereo output into shared memory. The HAL plug-in reads that final stream and presents it to Core Audio as the input from `Mixed Capture Audio`.

Shared memory is a live transport, not storage. The app should unlink shared memory when the session ends and should never persist mic, system, or mixed audio frames to logs, diagnostics, preferences, or support files.

```text
global system audio
        +
selected microphone
        v
Rust mixer in app process
        v
shared-memory ring buffer
        v
HAL plug-in
        v
QuickTime / Screenshot
```

Default shared-memory object name:

```text
/mca.mix.v1
```

Use the real bundle identifier once the project is created; keep the `.v1` suffix so incompatible layouts can move to a new name.

Shared-memory sandbox gate:

```text
1. App creates and initializes the shared-memory object.
2. HAL plug-in loaded by coreaudiod opens and maps the object.
3. HAL plug-in reads known test frames.
4. Missing/invalid/stale data returns silence.
5. No sandbox deny appears for required shm_open/mmap operations.
```

If this gate fails, do not continue with the POSIX shared-memory data plane as designed. Prototype the non-real-time Mach/XPC setup fallback documented in the control-plane section.

Shared format:

- sample rate: 48 kHz
- channels: 2
- sample format: Float32
- layout: interleaved stereo
- HAL-facing shared ring default capacity: about 250 ms
- HAL-facing target fill: fixed V1 ABI constant, 50 ms / 2400 frames at 48 kHz
- source-side buffers may be larger, such as about 1 second, because they are not directly reported as HAL device latency

ABI constants:

```c
#define MIXED_AUDIO_SHM_MAGIC 0x4D415544u
#define MIXED_AUDIO_ABI_VERSION 1u
#define MIXED_AUDIO_SHM_VERSION MIXED_AUDIO_ABI_VERSION
#define MIXED_AUDIO_OUTPUT_SAMPLE_RATE 48000u
#define MIXED_AUDIO_OUTPUT_CHANNEL_COUNT 2u
#define MIXED_AUDIO_TARGET_SHARED_FILL_MS 50u
#define MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES 2400u
```

The target shared-ring fill is not a runtime source of truth for HAL latency. The HAL must report latency from the fixed ABI constant even when the app is not running and the shared-memory object does not exist. If the target fill changes, bump the app/HAL ABI version and shared-memory object name.

Header contract:

```c
#define MIXED_AUDIO_SHM_MAGIC 0x4D415544u
#define MIXED_AUDIO_ABI_VERSION 1u
#define MIXED_AUDIO_SHM_VERSION MIXED_AUDIO_ABI_VERSION
#define MIXED_AUDIO_OUTPUT_SAMPLE_RATE 48000u
#define MIXED_AUDIO_OUTPUT_CHANNEL_COUNT 2u
#define MIXED_AUDIO_TARGET_SHARED_FILL_MS 50u
#define MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES 2400u

typedef struct mixed_audio_shm_header {
    uint32_t magic;
    uint32_t version;
    uint32_t sample_rate;
    uint32_t channel_count;
    uint32_t capacity_frames;
    uint32_t target_shared_fill_frames;
    _Atomic uint64_t write_frame_index;
    _Atomic uint64_t read_frame_index;
    _Atomic uint64_t generation;
    _Atomic uint64_t producer_heartbeat_nanos;
    _Atomic uint64_t underrun_count;
    _Atomic uint64_t overrun_count;
    _Atomic uint64_t dropped_frame_count;
    _Atomic uint64_t clipped_frame_count;
} mixed_audio_shm_header_t;
```

Audio data starts immediately after the header at an alignment suitable for `float`.

Shared memory has two logical sections:

```text
Header / metadata
  - identity: magic, version
  - format: sample rate, channel count, capacity
  - compatibility mirror: target shared fill frames
  - synchronization: write index, read index, generation
  - liveness: producer heartbeat
  - diagnostics: underrun, overrun, dropped-frame, clipped-frame counters

Audio ring buffer
  - interleaved stereo Float32 frames
  - frame 0: left, right
  - frame 1: left, right
  - frame 2: left, right
```

The shared-memory region does not store microphone-only audio, system-only audio, app policy, source names, UI state, or permission state. Those stay in the app process.

## Correctness Model

Correctness comes from a simple single-producer/single-consumer contract plus conservative failure behavior.

Producer:

```text
1. Mix captured source buffers into 48 kHz stereo Float32 frames.
2. Copy complete frames into the ring buffer.
3. Publish the new write index with atomic release ordering.
4. Update heartbeat and counters.
```

Consumer:

```text
1. Validate header, generation, format, and heartbeat.
2. Read the producer write index with atomic acquire ordering.
3. Compute available frames.
4. Copy available frames into the Core Audio output buffer.
5. Silence-fill any missing frames.
6. Advance the read index only for frames actually consumed.
```

Core guarantees:

- There is one writer: the app-owned Rust mixer.
- There is one reader: the HAL plug-in.
- The read index advances only while HAL IO is actively serving a recording/client.
- If no client is recording, the producer may lap the ring and drop old frames; this is expected and counted as overrun/dropped frames.
- The audio format is fixed for v1: 48 kHz, stereo, Float32, interleaved.
- The producer publishes `write_frame_index` only after audio frames are fully copied.
- The consumer never reads beyond the published `write_frame_index`.
- The producer publishes `write_frame_index` with release ordering.
- The consumer acquires `write_frame_index` before reading frames.
- The consumer never blocks; insufficient data becomes silence.
- Shared-ring fill level is the producer-to-HAL clock-coupling signal.
- The producer should target the fixed shared-ring fill ABI constant rather than blindly filling as fast as source callbacks arrive.
- The target shared-ring fill constant is intentional latency and must be included in HAL-reported input/device latency.
- `generation` protects against app restart or shared-memory reinitialization.
- `producer_heartbeat_nanos` protects against stale producer state.
- Counters make transport health visible to app diagnostics.

Failure philosophy:

```text
Bad data never beats silence.
```

If any validation fails, the HAL plug-in returns silence. This includes missing shared memory, invalid header, unsupported version, stale heartbeat, generation mismatch, and underrun.

## Producer Rules

The Swift app owns the producer lifecycle. Rust owns the mixer and shared-memory writer implementation.

- Callback-facing Swift-to-Rust FFI functions should only copy source frames into preallocated Rust buffers, update atomics/counters, and return. Mixing and shared-memory writing happen in a bounded Rust processing step.
- Mixing/shared-memory writing is driven by a dedicated active-session mixer thread targeting the HAL 48 kHz output cadence, not directly by the system tap callback or an ordinary app dispatch timer.
- The mixer thread should use high-QoS scheduling at minimum; prototype whether a real-time-class/pthread time-constraint policy is required.
- Active sessions must prevent App Nap and timer coalescing from starving the mixer path.
- Measure worst-case mixer wakeup latency under load. The fixed target fill must exceed realistic wakeup jitter with margin, or the ABI constant and HAL-reported latency must be raised together.
- Rust monitors shared-ring fill level and applies bounded final-stage rate trim to avoid producer-to-HAL drift.
- Create and initialize shared memory before starting the HAL-visible session.
- Validate and write the header before writing frames.
- Increment `generation` when the producer restarts or the buffer is reinitialized.
- Update `producer_heartbeat_nanos` periodically while the session is active.
- Write only interleaved 48 kHz stereo Float32 frames.
- Advance `write_frame_index` only after frames are fully written.
- If the writer would lap the reader, drop the oldest unread frames and increment `overrun_count` and `dropped_frame_count`.
- Keep the shared ring near the fixed target-fill ABI constant when a HAL client is actively reading.
- Treat shared-ring fill error as sync-relevant: `actual_fill - MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES` is residual A/V sync error from the app-to-HAL buffer.
- On clean stop, stop writing frames, leave the last counters visible, and unlink/clean up according to the app lifecycle policy.

## Consumer Rules

The HAL plug-in owns the consumer behavior but not the session policy.

- Open and map shared memory lazily when IO starts or when prior validation failed.
- Validate `magic`, `version`, sample rate, channel count, and capacity before reading.
- Never block waiting for the app, shared memory, or more frames.
- Never call XPC, Swift, Objective-C, logging, file I/O, or client HAL APIs from the IO path.
- If shared memory is missing, invalid, stale, or underrun, fill the requested output with silence.
- If some frames are available but fewer than requested, copy available frames and silence-fill the remainder.
- Advance `read_frame_index` only for frames actually consumed.
- If `generation` changes, resync read position and output silence until valid frames are available.
- Treat a stale heartbeat as producer unavailable and output silence.

## Control Plane

V1 does not need a rich plug-in-to-app control channel. Keep control app-local unless a concrete need appears.

Allowed v1 control/state paths:

- Swift app reads shared-memory health counters on a timer for diagnostics.
- Swift app owns all user-facing session state.
- HAL plug-in exposes normal HAL device properties and read-only availability behavior.

Do not call XPC or Mach messaging from the HAL IO path. If future diagnostics require plug-in-to-app communication, add a non-real-time XPC/Mach channel that is only used outside IO callbacks.

Fallback if POSIX shared memory is blocked by the `coreaudiod` sandbox:

- Add `AudioServerPlugIn_MachServices` to the HAL plist for a narrowly scoped app/helper Mach service.
- Use the service only during non-real-time setup, reconnect, teardown, or diagnostics.
- Do not send audio frames over XPC/Mach from the IO callback.
- Establish any required mapping, descriptor, or configuration before IO begins.
- If a fallback cannot keep the IO path pre-established, non-blocking, and allocation-free, pause the architecture and reassess.

## Lifecycle

Start:

1. App launches.
2. App checks whether the HAL driver is installed and loadable.
3. App requests/validates microphone and system-audio permissions.
4. App creates and initializes shared memory.
5. App starts global system audio tap and selected mic capture.
6. App starts Rust mixer.
7. Rust mixer writes frames and heartbeat to shared memory.
8. User selects `Mixed Capture Audio` in QuickTime.
9. HAL plug-in opens shared memory and reads frames.

Stop:

1. User stops session in the app.
2. App stops capture sources.
3. App stops Rust mixer writes.
4. HAL plug-in detects missing/stale/insufficient frames and returns silence.
5. App may keep shared memory mapped for diagnostics or unlink during shutdown.

Crash/restart:

1. HAL plug-in returns silence when heartbeat becomes stale.
2. Restarted app creates or reinitializes shared memory and increments `generation`.
3. HAL plug-in notices generation change, resyncs, and resumes reading once valid frames arrive.

## Failure Behavior

| Failure | App behavior | HAL behavior |
|---|---|---|
| App not running | Diagnostics unavailable unless app launches | Output silence |
| Shared memory missing | Create it on session start | Output silence |
| Header invalid | Reinitialize or report diagnostics | Output silence |
| Heartbeat stale | Restart session or report degraded state | Output silence |
| Ring underrun | Increment/report underrun count | Silence-fill missing frames |
| Ring overrun | Drop oldest unread frames | Continue from updated read position |
| Mic unplug | Report degraded state and continue system audio if possible | Continue reading mixed frames or silence |
| System tap failure | Report degraded state and continue mic if possible | Continue reading mixed frames or silence |
| App restart | Reinitialize, increment generation | Resync on generation change |

## Per-App Audio Groundwork

Per-app audio routing is not a v1 user-facing feature. Keep the process boundary neutral:

- HAL plug-in should not know whether frames came from global audio, app audio, mic audio, or future sources.
- Shared-memory header should not encode source-specific routing.
- App/Rust side may define `CaptureMode.globalSystemAudio` now and reserve future `CaptureMode.applicationAudio`.
- Future per-app routing changes should not require changing the HAL plug-in audio IO contract.

## Testing

Transport tests:

- Phase 1 gate: prove `coreaudiod` can open/map the app-created shared-memory object.
- If the gate fails, prove or reject the non-real-time Mach/XPC setup fallback before continuing.
- Producer writes known ramp frames; consumer reads the same frames.
- Consumer requests more frames than available and receives valid frames followed by silence.
- Missing shared memory returns silence.
- Invalid magic/version returns silence.
- Stale heartbeat returns silence.
- Generation change forces resync.
- Writer overrun increments counters and keeps the newest frames.
- App restart resumes audio without restarting QuickTime.
- Diagnostics and preferences do not contain audio samples or recordings.
- With no active HAL recording client, producer overrun/drop behavior is expected and counted.

Manual QuickTime tests:

- Start app, select `Mixed Capture Audio`, record system audio plus mic.
- Stop app while QuickTime still has `Mixed Capture Audio` selected; recording continues with silence rather than failure/noise.
- Restart app while QuickTime still has the virtual device selected; audio resumes after generation resync.

Diagnostics, preferences, logging, and privacy rules are documented in `/tmp/quicktime-mixed-audio-helper-diagnostics-preferences-and-privacy.md`.

## References

- Apple Core Audio docs: [Core Audio](https://developer.apple.com/documentation/CoreAudio)
- Apple Audio Server Driver Plug-in guide: [Creating an audio server driver plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- Apple QA1811: [AudioServerPlugIns and client HAL API restrictions](https://developer.apple.com/library/archive/qa/qa1811/_index.html)
- macOS shared memory API: [shm_open](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/shm_open.2.html)
