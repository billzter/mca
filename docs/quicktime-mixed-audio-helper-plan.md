# QuickTime MixedCaptureAudio Implementation Progression

## Summary

Build a developer-signed native macOS app that exposes one selectable virtual input device for QuickTime/Screenshot screen recording. The device mixes system/app audio plus microphone audio into a single stereo Core Audio input named `Mixed Capture Audio`.

Chosen defaults: Swift app, Rust audio engine, C HAL AudioServerPlugIn, POSIX shared-memory audio transport, macOS 14.2+ minimum, Core Audio process taps for global system audio, one selected microphone for v1, and Developer ID signing/notarization for distribution. The technical details document is the source of truth when this progression conflicts with it.

V1 records global system audio plus one selected mic. Per-app audio capture is not a v1 user-facing feature, but the architecture should leave a clean path for it: source descriptors, capture-mode enums, diagnostics, and internal tap plumbing should avoid assuming global-only forever.

## Documentation Roadmap

Create or maintain these supporting docs before the corresponding implementation phase:

- `/tmp/quicktime-mixed-audio-helper-technical-details.md`: source of truth for language ownership, real-time rules, Rust/C/Swift boundaries, and stack best practices.
- `/tmp/quicktime-mixed-audio-helper-architecture-and-process-boundaries.md`: app process, HAL/audio-server process, POSIX shared-memory ring buffer, control plane, health counters, lifecycle, and silence fallback.
- `/tmp/quicktime-mixed-audio-helper-repo-and-build-system.md`: repository layout, Xcode targets, Rust crate layout, generated headers, universal builds, linking, signing, notarization, installer, and uninstaller.
- `/tmp/quicktime-mixed-audio-helper-plist-requirements.md`: app and HAL `Info.plist` keys, bundle identifiers, privacy strings, and plug-in factory metadata.
- `/tmp/quicktime-mixed-audio-helper-update-and-installation-strategy.md`: app-only updates, driver updates, package installer flow, version compatibility, and v1 decision to skip a privileged background helper.
- `/tmp/quicktime-mixed-audio-helper-hal-plugin-spec.md`: HAL bundle structure, factory entry point, device model, property selectors, IO lifecycle, advertised formats, reload/restart behavior, and standalone test approach.
- `/tmp/quicktime-mixed-audio-helper-rust-audio-engine-spec.md`: FFI structs/functions, mixer behavior, ring buffer contract, gain/limiter rules, health counters, and Rust unit-test fixtures.
- `/tmp/quicktime-mixed-audio-helper-permissions-and-user-flows.md`: first launch, permission prompts, denied-permission handling, System Settings guidance, diagnostics copy, and QuickTime setup flow.
- `/tmp/quicktime-mixed-audio-helper-diagnostics-preferences-and-privacy.md`: local diagnostics, logging rules, diagnostic export, preferences storage, privacy constraints, and the product promise that the app does not record or store audio.
- `/tmp/quicktime-mixed-audio-helper-test-and-validation-plan.md`: executable acceptance scenarios, long-run checks, drift measurement, underrun measurement, manual QuickTime script, and expected outputs.
- `/tmp/quicktime-mixed-audio-helper-remaining-confirmations.md`: prototype evidence still needed for driver permissions, Core Audio reload behavior, Sparkle/package updates, TCC resets, numeric thresholds, and signing.
- `/tmp/quicktime-mixed-audio-helper-design-review-resolution.md`: accepted design-review findings, shared-memory sandbox gate, ASRC/drift ownership, system-audio permission correction, process-tap aggregate-device plumbing, HAL timing, atomics, and single-consumer semantics.
- `/tmp/quicktime-mixed-audio-helper-design-review-round2-resolution.md`: producer-to-HAL shared-ring clock control, stronger system-audio access states, and duration-based buffer capacities.
- `/tmp/quicktime-mixed-audio-helper-design-review-round3-resolution.md`: target shared-ring fill latency reporting, `mixer_tick_frames` semantics, health snapshot atomic scope, and proceed-unverified onboarding.
- `/tmp/quicktime-mixed-audio-helper-design-review-round4-resolution.md`: fixed target-fill ABI contract, app-stopped HAL latency reporting, mixer scheduling robustness, and wakeup-jitter testing.
- `/tmp/quicktime-mixed-audio-helper-design-review-round5-resolution.md`: residual sync error from shared-ring fill-control band and v1 target-fill ABI freeze decision.

## Progression

### Phase 0: Proof Of Signal

- Build a Swift command-line or minimal app harness that creates a Core Audio process tap for global system audio on macOS 14.2+.
- Include the real process-tap capture path: tap creation, private aggregate-device creation, IO proc/block startup, stream format discovery, capture callback, and teardown.
- Capture one selected microphone/input device through Apple-native setup code.
- Build the first Rust mixer crate and expose it through a C ABI; Swift passes captured buffers into Rust.
- Mix global system audio and mic audio into a local WAV file for 30 seconds.
- Include source descriptors and a capture-mode enum that support `globalSystemAudio` now and reserve room for per-app modes later.
- Acceptance: recorded WAV contains both computer audio and mic audio, and the harness records the actual source formats/cadences that must be handled by the Phase 2 drift/rate-matching strategy.

### Phase 1: Virtual Device Spike

- Create a minimal HAL AudioServerPlugIn `.driver` that exposes one stereo input device named `Mixed Capture Audio`.
- Feed it generated silence/sine first, then replace the tone with frames read from POSIX shared memory.
- Gate the data plane with a shared-memory-across-`coreaudiod` sandbox spike: prove the HAL plug-in can `shm_open`/map the app-created object on a clean target Mac.
- If POSIX shared memory is denied by sandboxing, stop and prototype the non-real-time Mach/XPC setup fallback before continuing.
- Implement the first app-created shared-memory/ring-buffer handoff only after the sandbox spike passes: the app-owned Rust mixer writes frames, and the HAL plug-in opens shared memory and reads frames through minimal C code.
- Define the silence fallback: when the app is stopped, the shared buffer is unavailable, or the buffer underruns, the HAL plug-in returns silence without blocking.
- Implement a host-time-anchored `GetZeroTimeStamp` strategy and measure whether reported latency keeps QuickTime A/V sync acceptable.
- Add an installer helper that copies the signed driver to `/Library/Audio/Plug-Ins/HAL` and prompts for the required restart/reload flow.
- Acceptance: QuickTime's screen recording microphone menu shows `Mixed Capture Audio`, and recording captures the generated/mixed signal.

### Phase 2: Mixer Engine

- Implement the Rust audio engine with three v1 responsibilities:
  - Accept global system audio captured through Core Audio process taps.
  - Capture one selected microphone/input device.
  - Align, rate-match, gain-adjust, and mix sources into a stereo 48 kHz stream for the HAL device.
- Rust owns the long-term source alignment, drift monitoring, and rate-matching policy. Swift/Core Audio capture adapters may normalize simple source formats before calling Rust, but the public engine API must not assume all sources naturally arrive at 48 kHz.
- Producer-to-HAL drift is controlled by tracking shared-ring fill level, targeting the fixed ABI fill constant, and applying bounded final-stage rate trim.
- The HAL-facing target fill is a fixed V1 ABI constant, not a user/runtime tuning knob for latency purposes. The app/Rust mixer must target the same constant that the HAL reports as device latency.
- The residual difference between actual shared-ring fill and the fixed target-fill constant is residual A/V sync error; Phase 2 must measure and bound that control band.
- `mixed_audio_engine_mix_available` runs on a dedicated active-session mixer thread targeting the 48 kHz HAL cadence; source callbacks only push source data.
- The mixer thread must be scheduled with high-QoS or real-time-class behavior, with active-session App Nap/timer-coalescing prevention and wakeup-jitter measurement.
- Treat 44.1 kHz output/tap scenarios and 10-minute drift as Phase 2 requirements.
- Keep the public app-level interface small:
  - `startSession(config: CaptureSessionConfig)`
  - `stopSession()`
  - `listInputDevices()`
  - `listSupportedCaptureModes()`
- Keep per-app groundwork internal for now:
  - `CaptureMode.globalSystemAudio` is the only user-facing v1 mode.
  - Reserve `CaptureMode.applicationAudio` and source descriptor fields for future per-app capture, but do not expose app include/exclude UI in v1.
  - Avoid naming APIs `listCapturableAudioProcesses()` until per-app capture is implemented.
- `CaptureSessionConfig` includes: selected mic device ID, capture mode, mic gain, system gain, monitor output device, mute-monitor flag, source buffer capacity duration, and shared buffer capacity duration. The HAL-facing target shared-ring fill comes from the app/HAL ABI contract and is not user-tunable in v1.
- Acceptance: mixer runs for 10 minutes with 44.1 kHz and 48 kHz source scenarios, and runs 30-60 minutes under normal and loaded conditions without recurring shared-ring fill drift, wakeup-jitter-driven underruns, residual fill-error sync drift beyond the release budget, repeated underruns, obvious drift, or device disconnect crashes.

### Phase 3: Menu-Bar App

- Build a SwiftUI/AppKit menu-bar app.
- UI includes:
  - session start/stop
  - mic selector
  - global system audio enable/status
  - mic/system gain sliders
  - level meters
  - output monitoring toggle
  - permissions/status panel
- Do not expose per-app include/exclude controls in v1; show only global system audio status.
- Store preferences in app settings; do not require users to reconfigure every launch.
- Do not store recordings or audio content; `MixedCaptureAudio` only enables a live audio path for QuickTime or another recording app.
- Acceptance: a non-developer can install, grant permissions, choose sources, start mixing, and select `Mixed Capture Audio` in QuickTime.

### Phase 4: Reliability And Distribution

- Add signed installer/uninstaller flows for the app and HAL driver.
- Add first-run diagnostics:
  - driver installed
  - driver loaded
  - system audio access test passes
  - microphone permission granted
  - selected devices available
- Add recovery for default output changes, mic unplug, global process-tap failure, sample-rate changes, and sleep/wake.
- Add explicit install, uninstall, reload/restart, signing, and notarization documentation before shipping this phase.
- Acceptance: app recovers cleanly from common device changes and provides clear status when it cannot.

### Phase 5: Optional Per-App Audio Routing

- Only start this after the global system audio plus mic QuickTime helper is working.
- Promote the reserved per-app groundwork into user-facing behavior.
- Add app/process discovery, include/exclude capture controls, diagnostics for unavailable processes, and per-app failure handling.
- Preserve the same virtual device contract: QuickTime still sees exactly one mixed input.
- Acceptance: user can choose global system audio or selected app/process audio plus mic, and QuickTime records the mixed result.

### Phase 6: Optional Full Recorder Track

- Only start this after the QuickTime helper and any desired per-app audio routing are working.
- Reuse the mixer engine.
- Add ScreenCaptureKit recording with display/window/app selection.
- Record video plus mixed audio directly to `.mov`.
- Acceptance: app can produce a screen recording without QuickTime, but this remains a separate product milestone.

## Public Interfaces

- Virtual Core Audio input device: `Mixed Capture Audio`.
- App API:
  - `CaptureSessionConfig`
  - `AudioSourceDescriptor`
  - `CaptureSessionState`
  - `AudioMixerEngine`
  - `VirtualDeviceBridge`
  - `CaptureMode`
- User-facing contract: QuickTime sees exactly one input; all multi-source complexity stays inside our app.
- V1 user-facing capture mode: global system audio plus one selected mic.
- Future capture mode groundwork: app/process descriptors and capture-mode enum exist, but per-app include/exclude behavior is not exposed until Phase 5.

## Test Plan

- Rust unit tests cover mixer gain, clipping/limiting, silence handling, stereo output shape, ring-buffer underrun/overrun behavior, config snapshots, and health counters.
- Swift unit tests cover device/source enumeration, permission state mapping, diagnostics state, and session-controller state transitions.
- Integration test 30-second and 10-minute mixed recordings.
- Integration test 30-60 minute shared-ring fill stability between app/Rust producer and HAL consumer.
- Integration test the shared app-to-HAL transport with normal reads, underruns, app stopped, and app restart.
- Manual QuickTime acceptance test:
  - select `Mixed Capture Audio`
  - record browser/system audio plus mic
  - verify playback includes both sources
- Failure tests:
  - deny mic permission
  - deny system audio permission
  - unplug mic mid-session
  - change output device mid-session
  - stop the app while QuickTime has selected the virtual device
  - sleep/wake during idle and active sessions

## Assumptions

- Minimum supported OS is macOS 14.2.
- Distribution uses Developer ID signing and notarization, not Mac App Store sandboxing.
- v1 prioritizes QuickTime/Screenshot compatibility over building a full recorder.
- v1 publishes a mixed stereo input, not separate multichannel tracks.
- v1 captures global system audio plus one selected mic.
- Per-app audio capture is future scope, with API and source-model groundwork included from the beginning.
- Swift owns product behavior, Rust owns deterministic audio logic, C owns the HAL plug-in ABI, and Objective-C++ remains optional glue.
- The HAL plug-in is a non-blocking shared-memory reader only; it does not capture, mix, own policy, or link the full Rust mixer engine in v1.
- Protected/DRM content may remain unavailable and is explicitly out of scope.
