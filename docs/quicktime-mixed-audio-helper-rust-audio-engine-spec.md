# QuickTime MixedCaptureAudio Rust Audio Engine Spec

## Summary

The Rust audio engine owns deterministic audio processing and the app-side shared-memory producer. Swift owns capture setup and user-facing behavior. The C HAL plug-in owns the virtual device ABI and reads shared memory.

Rust receives captured audio buffers through narrow C ABI functions, copies those buffers into preallocated source queues, aligns and rate-matches sources into one 48 kHz stereo Float32 output stream, applies gain and limiting, and writes the final mixed stream into POSIX shared memory.

Rust must not persist audio samples. It may maintain live in-memory buffers for mixing and shared-memory transport, but it must not write mic, system, or mixed audio to logs, diagnostics, preferences, or support files.

Hard rule:

```text
Callback-facing Rust FFI functions are copy-only, bounded, non-blocking, allocation-free, and panic-free.
```

## Responsibilities

Rust owns:

- C ABI exposed to Swift.
- Engine lifecycle.
- Source buffer ingestion.
- Preallocated source ring buffers.
- Source timing metadata ingestion.
- Source alignment, drift monitoring, and rate matching.
- Gain application.
- System plus mic mixing.
- Soft limiting and clipping counters.
- Silence handling for missing source frames.
- Shared-memory creation/mapping/writer logic.
- Health counters and health snapshots.
- Rust unit tests for audio math, ring behavior, FFI layout, and shared-memory writer behavior.

Rust does not own:

- Core Audio process tap creation.
- Microphone device selection.
- Microphone/system-audio permission prompts.
- SwiftUI/AppKit state.
- HAL plug-in callbacks.
- QuickTime behavior.
- Signing, installation, notarization, or driver reload.

## Source Format Contract

V1 HAL output format is fixed:

```text
sample rate: 48 kHz
channels: 2
sample format: Float32
layout: interleaved stereo
```

Captured sources may not naturally arrive in this format or stay clock-aligned. Swift/Core Audio capture adapters should discover the source format and may perform simple format normalization before calling Rust, but the Rust engine owns the long-term alignment, drift monitoring, and rate-matching policy.

V1 Rust API must therefore accept enough source metadata to distinguish:

```text
source sample rate
source channel count
source frame count
source host timestamp or source timestamp, where available
source identity: system or mic
```

Implementation note:

- Prototype may start with a simple rate-matching strategy.
- If source conversion is handled before Rust for an early spike, that is a temporary adapter decision, not the final ownership model.
- The engine contract must not assume all real devices naturally deliver stable 48 kHz audio forever.

## Crate Layout

```text
Rust/mixed-audio-engine/
  Cargo.toml
  cbindgen.toml
  src/
    lib.rs
    ffi.rs
    engine.rs
    format.rs
    source_buffer.rs
    mixer.rs
    limiter.rs
    shared_memory_writer.rs
    health.rs
  tests/
    ffi_layout_tests.rs
    mixer_tests.rs
    limiter_tests.rs
    source_buffer_tests.rs
    shared_memory_writer_tests.rs
```

Module responsibilities:

- `ffi.rs`: C ABI types/functions and raw-pointer validation.
- `engine.rs`: lifecycle, config snapshot, source routing, mixer step.
- `format.rs`: v1 constants and frame-size helpers.
- `source_buffer.rs`: preallocated single-producer/single-consumer source queues.
- `mixer.rs`: system/mic summing, gain, silence policy.
- `limiter.rs`: output soft limiter and clipping detection.
- `shared_memory_writer.rs`: POSIX shared-memory producer and ring writer.
- `health.rs`: atomic counters and snapshot conversion.

## C ABI

Expose C-compatible types only. All structs crossing FFI use `#[repr(C)]`, fixed-width integer types, and primitive fields.

Recommended API:

```c
typedef struct mixed_audio_engine mixed_audio_engine_t;

typedef enum mixed_audio_result {
    MIXED_AUDIO_OK = 0,
    MIXED_AUDIO_ERROR_NULL_POINTER = 1,
    MIXED_AUDIO_ERROR_INVALID_CONFIG = 2,
    MIXED_AUDIO_ERROR_INVALID_FORMAT = 3,
    MIXED_AUDIO_ERROR_NOT_RUNNING = 4,
    MIXED_AUDIO_ERROR_INTERNAL = 5
} mixed_audio_result_t;

typedef enum mixed_audio_capture_mode {
    MIXED_AUDIO_CAPTURE_MODE_GLOBAL_SYSTEM_AUDIO = 1,
    MIXED_AUDIO_CAPTURE_MODE_APPLICATION_AUDIO_RESERVED = 2
} mixed_audio_capture_mode_t;

typedef struct mixed_audio_config {
    uint32_t output_sample_rate;
    uint32_t output_channel_count;
    uint32_t source_buffer_capacity_ms;
    uint32_t shared_buffer_capacity_ms;
    uint32_t target_shared_fill_ms;
    uint32_t mixer_tick_frames;
    float system_gain;
    float mic_gain;
    mixed_audio_capture_mode_t capture_mode;
} mixed_audio_config_t;

V1 ABI constants:

```text
MIXED_AUDIO_ABI_VERSION = 1
MIXED_AUDIO_OUTPUT_SAMPLE_RATE = 48000
MIXED_AUDIO_OUTPUT_CHANNEL_COUNT = 2
MIXED_AUDIO_TARGET_SHARED_FILL_MS = 50
MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES = 2400
```

`target_shared_fill_ms` is retained in the Rust config only as a compatibility assertion and internal control input. In v1 it must equal `MIXED_AUDIO_TARGET_SHARED_FILL_MS`; it is not user-tunable. A mismatch returns `MIXED_AUDIO_ERROR_INVALID_CONFIG` and prevents the app from reaching `Ready`.

`mixer_tick_frames`:

- number of 48 kHz output frames Rust should attempt to produce per app-owned mixer tick
- expressed in output frames, not source frames
- driven by a dedicated active-session mixer thread using host/monotonic time
- scheduled with high-QoS or real-time-class behavior after prototype validation
- not driven directly by process-tap or microphone callbacks
- not driven by a general dispatch timer on a normal app queue

Recommended prototype config:

```text
source_buffer_capacity_ms = 1000
shared_buffer_capacity_ms = 250
target_shared_fill_ms = 50
mixer_tick_frames = 128
```

At 48 kHz, 128 frames is about 2.67 ms. Tune the tick size after CPU, jitter, and wakeup measurements. Tune the target fill only through an ABI/version change, because the HAL reports it as fixed device latency.

typedef struct mixed_audio_source_format {
    uint32_t sample_rate;
    uint32_t channel_count;
    uint32_t is_interleaved;
} mixed_audio_source_format_t;

typedef struct mixed_audio_source_timing {
    uint64_t host_time_nanos;
    uint64_t source_sample_time;
    uint32_t has_host_time;
    uint32_t has_source_sample_time;
} mixed_audio_source_timing_t;

typedef struct mixed_audio_health {
    uint64_t pushed_system_frames;
    uint64_t pushed_mic_frames;
    uint64_t mixed_frames;
    uint64_t shared_memory_written_frames;
    uint64_t system_underrun_frames;
    uint64_t mic_underrun_frames;
    uint64_t shared_memory_overrun_frames;
    uint64_t shared_memory_underrun_frames;
    uint64_t shared_ring_fill_frames;
    uint64_t target_shared_ring_fill_frames;
    int64_t shared_ring_fill_error_frames;
    double current_output_rate_trim;
    uint64_t clipped_frames;
    uint64_t callback_error_count;
    uint64_t generation;
    uint64_t last_heartbeat_nanos;
} mixed_audio_health_t;

mixed_audio_engine_t *mixed_audio_engine_create(const mixed_audio_config_t *config);
void mixed_audio_engine_destroy(mixed_audio_engine_t *engine);

mixed_audio_result_t mixed_audio_engine_start(mixed_audio_engine_t *engine);
void mixed_audio_engine_stop(mixed_audio_engine_t *engine);

mixed_audio_result_t mixed_audio_engine_push_system_audio(
    mixed_audio_engine_t *engine,
    const float *interleaved_stereo,
    uint32_t frame_count,
    const mixed_audio_source_format_t *format,
    const mixed_audio_source_timing_t *timing
);

mixed_audio_result_t mixed_audio_engine_push_mic_audio(
    mixed_audio_engine_t *engine,
    const float *interleaved_stereo,
    uint32_t frame_count,
    const mixed_audio_source_format_t *format,
    const mixed_audio_source_timing_t *timing
);

mixed_audio_result_t mixed_audio_engine_mix_available(mixed_audio_engine_t *engine);

mixed_audio_health_t mixed_audio_engine_health(const mixed_audio_engine_t *engine);
```

`mixed_audio_engine_push_system_audio` and `mixed_audio_engine_push_mic_audio` are callback-facing. They must copy input frames into preallocated source buffers and return quickly.

`mixed_audio_engine_mix_available` may run from a dedicated processing callback/thread or a controlled app-side processing path. It must still be bounded and non-blocking.

## Real-Time Callback Safety

Callback-facing FFI functions must only:

- Validate non-null pointers.
- Validate fixed format assumptions.
- Copy at most `frame_count * 2` `float` samples into a preallocated ring buffer.
- Advance atomic indices.
- Increment atomic counters.
- Return a small integer result.

Callback-facing FFI functions must not:

- Allocate heap memory.
- Resize a `Vec`.
- Lock a `Mutex` or wait on any blocking primitive.
- Log.
- Open files.
- Open/map shared memory.
- Call Swift or Objective-C.
- Call async runtimes.
- Wait for another audio source.
- Perform unbounded loops.
- Panic across FFI.

If a callback-facing function receives invalid arguments, it increments `callback_error_count` and returns an error code. It must not panic.

## Mixing Model

For each output frame:

```text
system_l = next system left sample or 0.0
system_r = next system right sample or 0.0
mic_l    = next mic left sample or 0.0
mic_r    = next mic right sample or 0.0

mixed_l = system_l * system_gain + mic_l * mic_gain
mixed_r = system_r * system_gain + mic_r * mic_gain

output_l = soft_limit(mixed_l)
output_r = soft_limit(mixed_r)
```

Default gains:

```text
system_gain = 1.0
mic_gain = 1.0
```

Before mixing, the engine aligns sources according to available timing metadata and the current rate-matching policy. If timing metadata is missing for a prototype source, use buffered frame availability and record a diagnostic counter so this limitation is visible.

If one source lacks aligned frames, mix the available source with silence and increment the missing source’s underrun counter.

If both sources lack frames, either write silence or skip writing depending on the processing cadence. Prefer writing silence while the session is active so HAL sees a steady stream.

## Drift And Rate-Matching Policy

Rust owns drift monitoring and rate matching.

Inputs:

- source format metadata
- source timing metadata
- per-source ring-buffer fill levels
- shared-ring fill level
- target shared-ring fill level
- underrun/overrun counters
- output cadence required by the 48 kHz HAL stream

V1 requirements:

- Support or explicitly reject 44.1 kHz source scenarios during prototype.
- Track drift between system and mic sources over long runs.
- Track drift between the app/Rust producer and HAL/coreaudiod consumer over long runs.
- Hold shared-ring fill near the fixed target-fill ABI constant.
- Apply a bounded final-stage output rate trim when shared-ring fill drifts from the fixed target.
- Keep output cadence stable for the HAL device.
- Avoid accumulating unbounded delay.
- Expose drift/rate-match health counters for diagnostics.

Mixer cadence:

- Source callbacks push data only.
- `mixed_audio_engine_mix_available` should be driven by an app-owned mixer tick, not directly by the system tap callback.
- The mixer tick is driven by a dedicated active-session mixer thread using host/monotonic time.
- The mixer thread must be protected from App Nap/timer coalescing while a session is active.
- Wakeup jitter must be measured under load and compared against the fixed target-fill ABI constant.
- The mixer tick targets the 48 kHz HAL output cadence and requests about `mixer_tick_frames` output frames per call.
- Rust uses source timing plus shared-ring fill level to decide how many output frames to produce and how to trim the effective output ratio.

Shared-ring fill control:

```text
target_shared_fill_frames = MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES
actual_shared_fill_frames = write_frame_index - read_frame_index
fill_error = target_shared_fill_frames - actual_shared_fill_frames
rate_trim = clamp(kp * fill_error, min_trim, max_trim)
effective_output_ratio = nominal_ratio + rate_trim
```

The prototype controller may be simple. The requirement is that producer-to-HAL drift is measured and corrected intentionally rather than left to occasional underrun/overrun glitches.

Fill-control band and residual sync:

```text
residual_sync_error_frames =
    actual_shared_fill_frames
  - MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES
```

Because HAL reports the fixed target-fill constant, any sustained fill error becomes residual A/V sync error. Track min/max/mean/p95/p99 fill error and tune rate trim so the fill-control band remains inside the release sync-error budget.

Latency coupling:

- Target shared-ring fill is intentional buffering in the A/V sync path.
- Keep the fixed target-fill ABI constant small by default.
- HAL must include `MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES` in reported input/device latency even when the app is not running.
- Prototype must validate A/V sync at the chosen ABI constant before increasing it.
- The 50 ms / 2400 frame value is a prototype default until v1 ABI freeze; before v1.0 it must be confirmed against wakeup jitter, underruns, fill-error band, and measured QuickTime A/V sync.

Prototype options:

- Simple linear interpolation SRC for early validation.
- Apple-side conversion for simple format normalization plus Rust-side drift monitoring.
- Dedicated Rust SRC/ASRC module once measured data shows the required complexity.

Do not hide drift problems behind broad acceptance language. Ten-minute mixed runs must validate source-to-source drift behavior, and 30-60 minute tests must validate shared-ring fill stability between the producer and HAL consumer.

## Limiter Policy

V1 limiter:

- Keep output in `[-1.0, 1.0]`.
- Increment `clipped_frames` when a pre-limiter sample exceeds `abs(1.0)`.
- Use a simple deterministic soft limiter.

Acceptable v1 limiter:

```text
soft_limit(x) = x / (1.0 + abs(x)) * 2.0
then clamp to [-1.0, 1.0]
```

If this sounds too colored in testing, replace it with a better deterministic limiter later. The API and counters should not change.

## Source Buffer Policy

Each source has a preallocated ring buffer:

- System source buffer.
- Mic source buffer.

Rules:

- Single writer per source callback.
- Single reader from mixer step.
- Capacity configured at engine creation.
- Capacity is configured in milliseconds and converted to frames for each source’s rate.
- On source buffer overrun, drop oldest unread frames and increment a dropped/underrun-related counter.
- Never block the source callback waiting for buffer space.

Recommended initial capacity:

```text
source_buffer_capacity_ms = 1000
shared_buffer_capacity_ms = 250
target_shared_fill_ms = 50
```

Source buffering is intentionally roomy for prototypes and can be reduced after measurement. The shared-ring target is much smaller because it sits in the A/V sync path. The engine converts source/shared buffer durations into frame counts based on source/output rates. The target fill must match `MIXED_AUDIO_TARGET_SHARED_FILL_MS`.

## Shared-Memory Writer Policy

Rust creates and writes the shared-memory data plane used by the HAL plug-in.

Rules:

- Initialize header before starting audio writes.
- Use the same C-compatible header documented in the architecture/process-boundaries doc.
- Write only interleaved 48 kHz stereo Float32 frames.
- Copy audio frames first.
- Publish `write_frame_index` only after frames are fully copied.
- Use release ordering when publishing `write_frame_index`.
- Update heartbeat while active.
- Increment `generation` on start/restart/reinitialization.
- Use `shared_buffer_capacity_ms` to size the HAL-facing ring and `MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES` to control its target fill.
- Track shared-ring fill level as the producer-to-consumer clock-coupling signal.
- Mirror `MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES` in the shared-memory header for diagnostics/compatibility, but do not rely on the header as the HAL latency source of truth.
- On shared-memory overrun, drop oldest unread frames and increment overrun/dropped counters.

Shared-memory writer setup may allocate/open/map memory during `start`, but never from callback-facing source push functions.

## FFI And Memory Safety

Rust memory safety does not automatically cover FFI or shared memory. Treat every FFI and shared-memory operation as unsafe until validated.

Rules:

- All FFI entry points are `extern "C"`.
- FFI functions validate raw pointers before use.
- No Rust references are stored from incoming raw pointers.
- Incoming audio buffers are copied before the FFI call returns.
- FFI structs use `#[repr(C)]`.
- No Rust `Vec`, `String`, slices, trait objects, or enums with unspecified layout cross FFI.
- No panics cross FFI; catch or prevent panic paths.
- Release builds prefer `panic = "abort"`.
- Shared-memory structs use C-compatible fixed-width fields.
- Shared-memory layout has tests for size, alignment, and offsets.
- Unsafe code is isolated in `ffi.rs` and `shared_memory_writer.rs`.

## Engine Lifecycle

Create:

1. Validate config.
2. Allocate source buffers.
3. Allocate mixer scratch buffers.
4. Create health counters.
5. Return opaque engine pointer.

Start:

1. Create/map shared memory.
2. Initialize shared-memory header.
3. Increment generation.
4. Mark engine running.
5. Begin heartbeat updates when frames are written.

Push source audio:

1. Validate engine pointer, input pointer, and frame count.
2. Validate engine is running.
3. Copy frames into source ring buffer.
4. Update pushed-frame counters.
5. Return immediately.

Mix:

1. Run on the app-owned mixer tick.
2. Snapshot source buffer fill and shared-ring fill.
3. Determine bounded frame count to mix for the 48 kHz output cadence.
4. Apply source alignment and rate matching.
5. Apply shared-ring fill trim to avoid producer-to-HAL drift.
6. Read available frames from each source.
7. Use silence for missing frames.
8. Apply gains.
9. Apply limiter.
10. Write final frames to shared memory.
11. Update health counters and heartbeat.

Stop:

1. Mark engine stopped.
2. Stop writing heartbeat.
3. Leave counters readable.
4. Release shared-memory resources according to app lifecycle policy.

Destroy:

1. Stop if still running.
2. Free allocated buffers.
3. Drop engine.

## Health And Diagnostics

Health counters should be atomic or collected from atomics into snapshots.

Expose:

- Pushed system frames.
- Pushed mic frames.
- Mixed frames.
- Shared-memory written frames.
- System underrun frames.
- Mic underrun frames.
- Shared-memory overrun frames.
- Shared-memory underrun frames, if known from reader feedback/counters.
- Shared-ring fill level.
- Shared-ring target fill.
- Shared-ring fill error.
- Current output rate trim.
- Clipped frames.
- Callback error count.
- Generation.
- Last heartbeat timestamp.

Swift reads `mixed_audio_engine_health` on a timer for diagnostics. Swift must not poll health from audio callbacks.

`mixed_audio_health_t` is a snapshot, not a shared-memory atomic header. Lock-free atomic requirements apply to cross-process shared-memory indices/counters. Signed fields and floating-point fields in `mixed_audio_health_t` are diagnostic snapshot values read outside real-time callbacks.

## Testing

Rust unit tests:

- `mixed_audio_config_t` accepts only 48 kHz stereo Float32 assumptions.
- Source format metadata accepts 44.1 kHz and 48 kHz prototype scenarios.
- Source timing metadata is copied and does not retain incoming pointers.
- Duration-based capacities convert correctly to per-source and shared-ring frame counts.
- FFI layout sizes are stable.
- Null engine pointer returns error.
- Null audio pointer returns error.
- Source push copies data and does not retain incoming pointer.
- System-only mix outputs system audio.
- Mic-only mix outputs mic audio.
- System plus mic mix applies gain correctly.
- Source alignment handles uneven system/mic timing without unbounded delay growth.
- Rate matching handles 44.1 kHz source to 48 kHz output in prototype tests or returns a clear unsupported-format error.
- Shared-ring fill control holds producer-to-HAL fill near `MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES` in simulation.
- Shared-ring fill error min/max/mean/p95/p99 remain within the chosen residual sync-error budget in simulation and long-run tests.
- `mixed_audio_engine_mix_available` behavior is driven by an app-owned mixer tick, not by source callbacks.
- Missing source frames produce silence and increment underrun counters.
- Limiter keeps samples within `[-1.0, 1.0]`.
- Clipping counter increments on pre-limiter overflow.
- Shared-memory header initializes with expected magic/version/format.
- Shared-memory writer publishes write index after writing frames.
- Shared-memory overrun drops oldest frames and increments counters.
- Health snapshot reports expected counters.
- Diagnostics can read counters without exposing audio sample data.

Stress tests:

- Push 128-frame buffers repeatedly for 10 minutes of simulated time.
- Push uneven system/mic buffer cadence and verify bounded underruns.
- Randomly vary source chunk sizes while preserving fixed format.
- Run 44.1 kHz and 48 kHz source-cadence simulations against 48 kHz output.
- Simulate small source-clock drift over 10 minutes and verify bounded buffer growth/underruns.
- Simulate producer-to-HAL clock drift for 30-60 minutes and verify bounded shared-ring fill.
- Verify final-stage rate trim remains within configured bounds.
- Verify no panics during invalid FFI argument tests.

## Acceptance Criteria

- `cargo test` passes.
- C ABI header generated by `cbindgen` matches the intended API.
- Swift can create/start/stop/destroy the engine.
- Swift can push system and mic buffers into Rust.
- Rust writes a final mixed stream into shared memory.
- Rust owns source alignment and rate-matching policy for long-running sessions.
- Rust uses shared-ring fill level as the producer-to-HAL clock-control signal.
- HAL shared-memory reader test can read Rust-written frames.
- No callback-facing FFI path allocates, blocks, logs, waits, or panics.
- 30-second proof recording contains mixed system audio plus mic.
- 10-minute stress run reports no repeated underrun pattern or obvious drift under normal 44.1 kHz and 48 kHz source scenarios.
- 30-60 minute stress run reports bounded shared-ring fill without recurring drift-induced underruns/overruns.
- No Rust path writes audio content to logs, diagnostics, preferences, or files.

## References

- Apple Audio Workgroups: [Understanding Audio Workgroups](https://developer.apple.com/documentation/audiotoolbox/understanding-audio-workgroups)
- Rust FFI Nomicon: [FFI](https://doc.rust-lang.org/nomicon/ffi.html)
- Rust atomics: [std::sync::atomic](https://doc.rust-lang.org/std/sync/atomic/)
