# QuickTime MixedCaptureAudio Technical Details

## Summary

Build a macOS QuickTime helper that exposes one virtual input device, `Mixed Capture Audio`, which mixes global system audio plus one selected microphone. The app uses Apple-native surfaces where Apple integration matters, and Rust where deterministic audio logic matters.

Recommended stack:

- **Swift**: app UI, permissions, settings, diagnostics, session orchestration.
- **Rust**: mixer engine, ring buffers, gain, limiting, counters, testable audio logic.
- **C**: minimal HAL AudioServerPlugIn boundary.
- **Objective-C++**: optional glue only if Swift-to-C ABI integration becomes awkward.
- **Shell/Xcode scripts**: build orchestration, install/uninstall, signing, notarization.

## Architecture

The app has two cooperating process domains:

```text
Swift menu-bar app process
  - owns UI, permissions, settings, diagnostics, source selection
  - creates global system audio tap, private aggregate device, IO proc/block, and selected mic input
  - calls Rust mixer through C ABI
  - creates and writes POSIX shared-memory ring buffer

Preferred POSIX shared-memory data plane
  - 48 kHz stereo Float32 interleaved frames
  - atomic read/write indices, generation, heartbeat, health counters
  - must be proven accessible from sandboxed coreaudiod before depending on it

HAL AudioServerPlugIn loaded by Core Audio host
  - exposes "Mixed Capture Audio"
  - opens shared memory if available
  - reads mixed frames without blocking
  - returns silence when app/buffer/data is unavailable

QuickTime / Screenshot
  - sees one microphone-like input: "Mixed Capture Audio"
```

The HAL plug-in should stay intentionally small. It advertises one virtual stereo input stream and reads mixed frames from the shared-memory ring buffer. If the app is stopped, the shared memory is unavailable, the heartbeat is stale, or the ring buffer underruns, it outputs silence.

Before deeper implementation, Phase 1 must prove that the HAL plug-in loaded by `coreaudiod` can open and map the app-created shared-memory object. If the sandbox blocks that path, prototype a non-real-time Mach/XPC setup fallback declared through `AudioServerPlugIn_MachServices`. Do not put XPC/Mach calls in the IO path.

The Swift app owns all user-facing behavior: permission prompts, source selection, gain controls, diagnostics, preferences, and session start/stop.

The hard rule: the HAL plug-in is a non-blocking shared-memory reader, not a capture engine, mixer, controller, logger, or policy owner.

Privacy rule: `MixedCaptureAudio` is not a recorder. It should not store mic audio, system audio, mixed audio, QuickTime recordings, transcripts, or audio sample dumps. It only maintains live buffers needed to feed the virtual input.

## Language Ownership

| Subsystem | Language | Rationale |
|---|---:|---|
| Menu-bar app | Swift + SwiftUI/AppKit | Best Apple UX and permission integration |
| Permissions and diagnostics | Swift | Native APIs, user-facing state, settings |
| Core Audio process tap + aggregate device setup | Swift or C bridge | Apple API surface; keep real-time work elsewhere |
| Microphone capture setup | Swift or C bridge | Native device discovery and permissions |
| Mixer engine, source alignment, drift/rate matching | Rust | Safer memory, deterministic core, strong tests |
| Ring buffers and counters | Rust | Atomics, ownership, testability |
| Gain, limiting, silence policy | Rust | DSP-like pure logic |
| Shared-memory transport | Rust writer + C reader | App writes through Rust; HAL reads through minimal C code |
| HAL virtual input device | C | Core Audio plug-in ABI is C-shaped |
| Swift/Rust interop | C ABI, optional Objective-C++ | Boring, stable boundary |
| Installer/signing scripts | Shell/Xcode | Apple tooling integration |

## Rust Integration Plan

Rust should build as a library consumed by the Swift app. The HAL plug-in should not link the full Rust mixer engine in v1; it should use a minimal C shared-memory reader that understands the same ring-buffer header/layout.

Recommended crate type:

```toml
[lib]
crate-type = ["staticlib"]
```

Expose only C-compatible functions:

```c
MixedAudioEngineHandle *mixed_audio_engine_create(MixedAudioEngineConfig config);
void mixed_audio_engine_destroy(MixedAudioEngineHandle *handle);

uint32_t mixed_audio_engine_push_system_interleaved_stereo(
    MixedAudioEngineHandle *handle,
    const float *samples,
    uint32_t frames);

uint32_t mixed_audio_engine_push_mic_mono(
    MixedAudioEngineHandle *handle,
    const float *samples,
    uint32_t frames);

uint32_t mixed_audio_engine_mix_available(
    MixedAudioEngineHandle *handle,
    float *output,
    uint32_t frames);

int32_t mixed_audio_engine_get_health(
    const MixedAudioEngineHandle *handle,
    MixedAudioEngineHealth *out_health);

MixedAudioSessionHandle *mixed_audio_session_create(MixedAudioSessionConfig config);
void mixed_audio_session_destroy(MixedAudioSessionHandle *handle);

int32_t mixed_audio_session_get_health(
    const MixedAudioSessionHandle *handle,
    MixedAudioEngineHealth *out_health);
```

Add a separate C-compatible shared-memory contract for the app-to-HAL boundary:

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

Shared-memory rules:

- Shared memory contains the final mixed stream written by the app-owned Rust mixer, not raw mic/system sources.
- The app creates, initializes, owns, and unlinks the shared-memory object.
- The HAL plug-in opens the shared-memory object if present; if open/mapping/validation fails, it returns silence.
- The app writes interleaved stereo Float32 frames.
- The HAL plug-in reads frames by advancing its read index; if available frames are insufficient, it fills the remainder with silence.
- Header fields use stable fixed-width C types and atomics; no Swift, Objective-C, or Rust-specific layout crosses this boundary.
- A stale heartbeat or generation mismatch forces the HAL plug-in to resync and output silence until valid frames are available.
- Correctness rule: the producer writes complete frames before publishing the write index; the consumer never reads beyond the published write index; any invalid or missing state becomes silence.

Rust FFI rules:

- Callback-facing Rust FFI functions are copy-only, bounded, non-blocking, allocation-free, and panic-free.
- Use `#[repr(C)]` for all structs crossing language boundaries.
- Release builds use `panic = "abort"`; an internal Rust panic is a fatal process bug, not a recoverable FFI error.
- Keep release panic paths nearly impossible by validating null pointers, invalid configs, oversized requests, and buffer shapes before unsafe access.
- `catch_unwind` guards may still fail closed in debug/test unwind builds, but release correctness must not depend on unwind catching.
- Keep ownership explicit: create/destroy functions own engine lifetime.
- Pass audio buffers as raw pointers plus frame counts.
- Return integer error codes at FFI boundaries.
- Full Rust engine rules live in `/tmp/quicktime-mixed-audio-helper-rust-audio-engine-spec.md`.

Sample-rate and drift rules:

- HAL output remains fixed at 48 kHz stereo Float32 in v1.
- Captured system/tap and microphone sources may not naturally arrive at 48 kHz or stay clock-aligned.
- Swift/Core Audio capture adapters may perform simple format normalization when Apple APIs make that straightforward.
- Rust owns long-term source alignment, drift monitoring, and rate matching so the mixer behavior is deterministic and testable.
- 44.1 kHz output/tap scenarios and 10-minute drift are explicit prototype requirements.
- Producer-to-HAL drift is controlled by tracking shared-ring fill level and applying bounded final-stage rate trim around the fixed V1 target-fill ABI constant.
- `mixed_audio_engine_mix_available` should be driven by a dedicated active-session mixer thread targeting the 48 kHz HAL output cadence, not directly by source callbacks or a general app dispatch timer.
- The target shared-ring fill setpoint is a fixed app/HAL ABI contract constant. The HAL must use that constant for latency reporting even when the app is stopped and shared memory does not exist.
- The residual difference between actual shared-ring fill and `MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES` is residual A/V sync error and must be measured as a release criterion.
- The shared-memory header may mirror `target_shared_fill_frames` for diagnostics and compatibility validation, but it is not the HAL's source of truth for latency reporting.
- While a capture session is active, prevent App Nap/timer coalescing from delaying the mixer path and measure worst-case wakeup jitter against the target-fill constant.

## Build Process

Rust support in Apple development is workable but not first-class. Expect a custom Xcode build phase.

Build flow:

1. Xcode Run Script invokes `cargo build`.
2. Build Rust for `aarch64-apple-darwin` and `x86_64-apple-darwin` if universal distribution is required.
3. Merge outputs with `lipo` when producing universal artifacts.
4. Generate C headers with `cbindgen`.
5. Link the Rust static library into the Swift app target.
6. Link the HAL plug-in against C/CoreAudio plus the minimal shared-memory reader only.
7. Sign and notarize the final app and HAL driver bundle.

This is manageable, but it adds real build orchestration. The benefit is worth it for the mixer engine, less worth it for the HAL plug-in itself.

## Best Practices

### Swift

- Use Swift for UI, settings, permissions, diagnostics, and lifecycle only.
- Keep UI state on `@MainActor`.
- Pass immutable config snapshots into the audio layer.
- Avoid Swift concurrency in callback-adjacent paths.
- Do not allocate, log, dispatch, or touch UI from audio callbacks.
- Keep service boundaries small: permissions, device discovery, session controller, diagnostics.

### Rust

- Use Rust for mixer logic and testable audio state.
- Use Rust for long-term source alignment, drift monitoring, and rate matching.
- Use Rust to implement the shared-memory producer/writer used by the app-owned mixer.
- Keep source-callback FFI functions narrow: validate pointers, copy frames into preallocated buffers, update atomics, return.
- Preallocate buffers before starting audio.
- Avoid heap allocation in hot paths.
- Avoid locks, blocking calls, logging, async, and file I/O in audio callbacks.
- Prefer atomics and lock-free queues/ring buffers.
- Keep DSP code explicit: v1 is 48 kHz, stereo, Float32.
- Track underruns, overruns, clipped frames, dropped frames, and ring-buffer fill level.
- Keep unsafe code isolated in small modules.

### C / HAL Plug-In

- Keep the HAL plug-in minimal.
- Implement only device identity, stream format, lifecycle, property handling, and frame reads.
- Advertise one stable input device: `Mixed Capture Audio`.
- Read mixed frames from shared memory using minimal C code.
- Output silence when no data is available.
- Never block waiting for the app or shared memory.
- Never call XPC, Swift, Objective-C, logging, file I/O, or client HAL APIs from the IO path.
- If a Mach/XPC fallback is required, use it only outside IO callbacks.
- Do not put app policy, source selection, or complex mixing inside the plug-in.

### Objective-C++

- Use only if needed as a bridge.
- Keep methods narrow and typed.
- Do not put business logic or audio mixing here.
- Do not allow Objective-C reference counting into real-time paths.

### Packaging

- Developer ID sign and notarize app plus HAL plug-in.
- Install HAL plug-in under `/Library/Audio/Plug-Ins/HAL`.
- Use app-only updates for changes that do not touch the HAL driver or shared-memory ABI.
- Use a signed/notarized package installer for HAL driver updates.
- Do not include a privileged background update helper in v1.
- Provide explicit uninstall.
- First-run diagnostics must report:
  - driver installed
  - driver loaded
  - driver compatible
  - mic permission
  - system audio access test status
  - selected mic availability
  - mixer health

Detailed update policy is documented in `/tmp/quicktime-mixed-audio-helper-update-and-installation-strategy.md`.

Diagnostics, preferences, logging, and privacy rules are documented in `/tmp/quicktime-mixed-audio-helper-diagnostics-preferences-and-privacy.md`.

## Testing

Acceptance tests:

- 30-second WAV proof contains system audio plus mic.
- QuickTime sees `Mixed Capture Audio`.
- QuickTime recording includes browser/system audio plus mic.
- HAL plug-in outputs silence when mixer is stopped.
- Shared-memory transport handles normal reads, underruns, app stopped, app restart, stale heartbeat, and generation changes.
- Shared-memory transport is proven from sandboxed `coreaudiod`, or the non-real-time fallback is proven before deeper implementation.
- 10-minute run across 44.1 kHz and 48 kHz source scenarios has no obvious drift or repeated underruns.
- System audio capture path includes process tap, private aggregate device, IO proc/block, stream format discovery, and teardown.
- HAL timing uses a host-time-anchored zero timestamp and measured latency keeps QuickTime A/V sync acceptable.
- App recovers or reports clearly on mic unplug, permission denial, output device change, sleep/wake, and process-tap failure.
- Diagnostic export contains metadata only and no audio content.
- Preferences persist user choices but do not persist permission truth, driver truth, or audio data.

Rust tests:

- gain math
- stereo mixing
- clipping/limiting
- silence insertion
- ring-buffer underrun/overrun behavior
- config snapshot application
- health counter increments

Manual tests:

- install driver
- restart/reload Core Audio if needed
- open QuickTime screen recording
- choose `Mixed Capture Audio`
- record computer audio plus mic
- verify playback

## Decision

Use **Rust instead of C++** for the mixer/audio-core layer.

Do **not** use Rust for the entire app. Keep Apple-native integration native:

```text
Swift owns product behavior.
Rust owns deterministic audio logic.
C owns the HAL plug-in ABI.
Objective-C++ remains optional glue.
```

This gives us Rust's strengths without forcing it into the Apple-specific HAL boundary where C remains the path of least pain.

Prototype confirmations still needed for driver permissions, Core Audio reload behavior, Sparkle/package updates, TCC resets, numeric thresholds, and signing are documented in `/tmp/quicktime-mixed-audio-helper-remaining-confirmations.md`.

## References

- Apple Core Audio docs: [Core Audio](https://developer.apple.com/documentation/CoreAudio)
- Apple system audio capture: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- Apple virtual/audio driver guidance: [Creating an audio device driver](https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver)
- WWDC21 guidance: [Create audio drivers with DriverKit](https://developer.apple.com/videos/play/wwdc2021/10190/)
- Rust Core Audio ecosystem example: [RustAudio/coreaudio-rs](https://github.com/RustAudio/coreaudio-rs)
