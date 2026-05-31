# QuickTime MixedCaptureAudio Test And Validation Plan

## Summary

Testing should prove each risky layer independently before relying on QuickTime. The validation order is:

```text
HAL load/plist spike
  -> shared-memory-across-coreaudiod sandbox spike
  -> process tap + aggregate-device capture spike
  -> Rust audio math and clock/SRC simulation
  -> shared-memory writer/reader
  -> HAL property surface
  -> HAL IO with synthetic signal
  -> Swift app integration
  -> install/update validation
  -> QuickTime manual acceptance
```

Do not use QuickTime as the first HAL test. By the time QuickTime is involved, Rust mixing, shared-memory transport, HAL device visibility, HAL timing, and HAL IO should already be proven.

Swift/AppKit/SwiftUI tests must use XCTest and be runnable through Xcode and `xcodebuild test`. Direct `swiftc`-compiled Swift test executables are not an accepted test layer.

## Test Layers

### Layer 1: Rust Unit Tests

Purpose:

- Prove deterministic audio math, FFI layout, source buffering, health counters, and shared-memory writer behavior.

Command:

```text
cargo test
```

Coverage:

- `mixed_audio_config_t` fixes output format assumptions: 48 kHz, stereo, Float32.
- Source format/timing metadata is accepted and copied safely.
- 44.1 kHz source to 48 kHz output prototype behavior is tested.
- FFI struct sizes and alignments are stable.
- C/Rust shared-memory struct offsets match exactly.
- Shared-memory atomics are lock-free on supported architectures.
- Null engine pointer returns an error.
- Null audio pointer returns an error.
- Source push copies data and does not retain incoming pointers.
- System-only mix outputs system audio.
- Mic-only mix outputs mic audio.
- System plus mic mix applies gain correctly.
- Missing system frames use silence and increment system underrun counters.
- Missing mic frames use silence and increment mic underrun counters.
- Limiter keeps output in `[-1.0, 1.0]`.
- Clipping counter increments when pre-limiter samples exceed `abs(1.0)`.
- Source buffer overrun drops oldest unread frames without blocking.
- Source queue overflow reports accepted frame counts and increments explicit overflow counters.
- Simulated source drift does not cause unbounded buffer growth.
- Shared-memory header initializes with expected magic/version/format.
- C and Rust shared-memory header size, alignment, and field offsets match exactly.
- Public Rust engine config/health structs have C-side size and alignment assertions in the generated header.
- Shared-memory writer writes frames before publishing `write_frame_index`.
- Shared-memory writer publishes `write_frame_index` with release ordering and reader acquires before reading.
- Shared-memory writer increments heartbeat and generation.
- POSIX shared-memory writer adopts a valid existing object, preserving write index and generation state for app restart recovery.
- Normal producer stop clears shared-memory audio frames and heartbeat without unlinking or resetting restart adoption state.
- Ordinary app termination stops the mixer synchronously and clears shared-memory audio/heartbeat without unlinking the app-owned POSIX object, preserving normal restart adoption behavior.
- Health snapshots report expected counters.
- Invalid FFI arguments do not panic.

Acceptance:

- All Rust tests pass.
- No callback-facing FFI path allocates, blocks, logs, waits, or panics.

Test isolation:

- App-hosted Xcode test teardown and ordinary release app termination must not discard `/mca.mix.v1`; explicit discard/reset paths remain responsible for unlinking the named production object.
- App-hosted Xcode test sessions automatically resolve native producer shared memory to `/mca.mix.test.<pid>` in debug/test builds when no explicit test override is set. These auto-XCTest mappings are unlinked immediately after mapping so test processes do not leak per-pid POSIX shared-memory objects.
- Native producer tests that need a specific POSIX transport may set `MCA_TEST_SHARED_MEMORY_NAME` to a short name with the `/mca.mix.test.` or `/mca.mix.debug.` prefix. Debug/test builds honor that override for the producer session and session-specific unlink path; release builds keep the fixed `/mca.mix.v1` app/HAL contract.
- A debug app run that finds `/mca.mix.v1` already owned by another producer must not adopt or unlink that object; it uses an isolated `/mca.mix.debug.<pid>` mapping instead. If the app acquires ownership but finds a fresh legacy heartbeat, it waits for the bounded heartbeat-stale window before adopting; if the heartbeat remains live, debug uses the isolated mapping and a second release producer fails session creation rather than double-writing the production ring.

### Layer 2: C Shared-Memory Reader Tests

Purpose:

- Prove the HAL-side reader without loading the HAL plug-in through Core Audio.

Test binary:

```text
MixedAudioSharedMemoryReaderTests
```

Coverage:

- Missing shared memory returns zero real frames and silence-fill path.
- Invalid magic returns zero real frames.
- Invalid version returns zero real frames.
- Unsupported sample rate returns zero real frames.
- Unsupported channel count returns zero real frames.
- Stale heartbeat returns zero real frames.
- Known ramp frames are copied exactly.
- Known sine frames are copied within expected tolerance.
- Partial availability copies available frames and silence-fills the remainder.
- Generation change forces resync.
- Overrun state keeps newest frames and increments counters.

Acceptance:

- Tests pass without installing the HAL driver.
- Reader never blocks waiting for shared memory or frames.
- Reader never crashes on invalid/missing shared-memory state.

### Layer 3: Swift App Unit Tests

Purpose:

- Prove app model, presentation, permission state mapping, preferences, diagnostics, selected-app behavior, and command/menu behavior without installing the HAL driver or relying on live recorder state.

Test runner:

```text
xcodebuild test -project MixedCaptureAudio.xcodeproj -scheme MixedCaptureAudioTests -configuration Debug
```

Coverage:

- Prerequisite status resolution and user-facing labels.
- Setup checklist presentation and action placement.
- Health diagnostics summaries and privacy-safe metadata.
- Microphone and selected-app persistence behavior.
- App model session state transitions.
- Debounced app/source refresh behavior.
- Source-level meter model and polling behavior.
- Standard app command menu behavior needed by AppKit text fields.

Acceptance:

- Tests are XCTest cases in an XCTest bundle.
- Tests use the Debug app product as their host and import the app module with `@testable import MixedCaptureAudio`.
- Tests are visible and runnable from Xcode.
- CI runs the same test bundle through `xcodebuild test`.
- Tests do not depend on QuickTime, installed HAL state, live audio devices, release credentials, or privileged system mutation.

### Layer 4: App-To-Reader Transport Tests

Purpose:

- Prove Rust writer and C reader agree on shared-memory layout.

Setup:

- Start Rust engine in a test harness.
- Write known synthetic frames through Rust shared-memory writer.
- Read frames with the C shared-memory reader.

Coverage:

- Header fields match expected values.
- Reader sees `MIXED_AUDIO_SHM_MAGIC`.
- Reader sees `MIXED_AUDIO_SHM_VERSION`.
- Reader sees `MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES` mirrored in the header.
- Reader sees 48 kHz, stereo, Float32.
- Known frame sequence survives writer-to-reader handoff.
- Writer restart increments generation.
- Reader resyncs after generation change.
- Heartbeat freshness changes reader behavior.

Acceptance:

- Rust-written frames are read correctly by the C reader.
- Invalid/stale state becomes silence.

### Layer 5: HAL Plug-In Load And Property Tests

Purpose:

- Prove Core Audio can load the `.driver` and see the expected virtual input device.

Prerequisite:

```text
Scripts/manage-installation.sh install-driver
```

Validation tool:

- A small Core Audio diagnostic tool or app diagnostic mode.

Coverage:

- Core Audio enumerates `Mixed Capture Audio`.
- Device is input-only.
- Device has one input stream.
- Device has zero output streams.
- Device reports nominal sample rate 48000.
- Device reports stereo Float32 format.
- Device reports alive when app is not running.
- Device remains visible when shared memory is missing.
- `GetZeroTimeStamp` reports host-time-anchored, monotonic timing.
- Reported latency is captured for later QuickTime A/V sync validation.

Acceptance:

- `Mixed Capture Audio` appears as an input device.
- Property queries do not crash or hang.
- Missing app/shared memory does not remove the device.
- Timing properties do not depend on app producer heartbeat or shared-memory availability.

### Layer 5A: Shared-Memory Across `coreaudiod` Sandbox Spike

Purpose:

- Prove the preferred POSIX shared-memory data plane works from the sandboxed HAL host before relying on it.

Setup:

- Install/load HAL driver.
- Start a tiny app-side producer that creates `/mca.mix.v1`.
- Write known ramp/sine frames and heartbeat.
- Have the HAL plug-in open/map/read the object from inside `coreaudiod`.
- Check logs for sandbox denies.

Coverage:

- HAL plug-in can `shm_open` the app-created object.
- HAL plug-in can `mmap` the object.
- HAL plug-in can validate the header.
- HAL plug-in can read known frames.
- Missing object returns silence.
- Invalid object returns silence.
- Sandbox denial is detected and reported.

Acceptance:

- Continue with POSIX shared memory only if this passes on a clean target Mac.
- If it fails, stop and run the non-real-time Mach/XPC setup fallback spike before deeper implementation.

### Layer 5B: Non-Real-Time Mach/XPC Setup Fallback Spike

Purpose:

- Prove or reject the fallback if the direct shared-memory path is blocked.

Coverage:

- HAL plist declares a narrow `AudioServerPlugIn_MachServices` entry.
- HAL plug-in can contact the app/helper service outside IO callbacks.
- Any required mapping, descriptor, or configuration is established before IO.
- IO callback does not call XPC/Mach, allocate, block, or log.

Acceptance:

- Fallback is acceptable only if audio IO remains real-time safe.
- If fallback cannot satisfy this, reassess the virtual-device architecture.

### Layer 6: HAL IO With Synthetic Signal

Purpose:

- Prove HAL can serve audio buffers from shared memory through Core Audio.

Setup:

- Install/load HAL driver.
- Start a synthetic shared-memory producer that writes one of:
  - silence
  - sine wave
  - ramp
  - alternating left/right pattern
- Record from `Mixed Capture Audio` using a small Core Audio test recorder.

Coverage:

- App stopped or no producer: recorded WAV is silence.
- Sine producer: recorded WAV contains expected sine frequency.
- Ramp producer: recorded WAV contains expected frame pattern.
- Alternating L/R producer: channel order is correct.
- Stale heartbeat: recorded WAV becomes silence.
- Generation change: audio pauses/resyncs then resumes.
- Partial underrun: missing frames become silence, not stale/noise.

Acceptance:

- HAL IO succeeds without QuickTime.
- Captured WAV matches expected synthetic signal.
- Invalid/missing data becomes silence.

### Layer 7: Swift App Integration Tests

Purpose:

- Prove app services, permissions state mapping, diagnostics, and Rust engine integration.

Coverage:

- Permission status maps to PascalCase diagnostics states.
- HAL driver state maps to `AudioDeviceStatus`.
- Selected mic state maps to `SelectedDeviceStatus`.
- Session state transitions are valid:
  - `Stopped`
  - `CheckingPrerequisites`
  - `RequestingPermissions`
  - `Ready`
  - `Starting`
  - `Running`
  - `Degraded`
  - `Stopping`
  - `Failed`
- Swift can create/start/stop/destroy Rust engine.
- Swift can create a Core Audio process tap, private aggregate device, and IO proc/block for system audio.
- Swift can tear down the process tap and aggregate device cleanly.
- Swift can push synthetic and captured system/mic buffers into Rust with source format/timing metadata.
- App creates shared memory through Rust engine.
- Diagnostics read health counters.
- Diagnostic export contains allowed metadata and excludes audio content.
- Settings persist selected user preferences.
- Settings do not persist permission truth or driver compatibility truth.
- Mic missing produces degraded state.
- System tap failure produces degraded state.
- 44.1 kHz and 48 kHz source scenarios are either handled or produce explicit unsupported-state diagnostics.

Acceptance:

- App can reach `Ready` when prerequisites are satisfied.
- App can reach `Running` when capture/mixing starts.
- App reports `Degraded` rather than crashing when one source fails.
- App never writes mic, system, or mixed audio to logs, diagnostics, preferences, or support files.

### Layer 8: Permissions And Onboarding Tests

Purpose:

- Prove first-run and denied-state flows are understandable and recoverable.

Coverage:

- First launch opens setup window.
- Missing HAL driver shows install action.
- Installed-but-not-loaded driver shows reload/restart guidance.
- `NotDetermined` microphone status shows pre-prompt.
- Denied microphone status shows System Settings guidance.
- System audio access uses a test-capture flow rather than a direct query/request API.
- `NotTested` system audio access shows pre-prompt.
- `PromptExpected` explains that starting the test path may trigger macOS permission UI.
- `Started` system audio access does not count as ready until audio is observed.
- `WaitingForSignal` prompts the user to play system audio.
- `ReceivingAudio` is required before setup claims fresh system audio has been observed.
- `Silent` state does not automatically become ready or denied without user guidance.
- Prior stored verification may display as `ProceedUnverified`, but fresh live confidence still requires observed audio.
- During active QuickTime/Screenshot recording, system audio can auto-verify when the virtual input is running and raw source-meter peaks prove non-silent computer audio.
- Failed system audio test shows System Settings guidance.
- `Check Again` refreshes states.
- Durable readiness does not wait for live system-audio confidence; the system-audio row remains an onboarding/diagnostic confidence item.

Manual reset command for microphone:

```text
tccutil reset Microphone <bundle-id>
```

Manual reset command for Screen & System Audio Recording:

```text
tccutil reset ScreenCapture <bundle-id>
```

Acceptance:

- User can recover from denied permissions.
- User can continue setup on a quiet machine without the app falsely claiming verified system audio.
- App never starts capture invisibly.
- App clearly distinguishes durable setup readiness from live verification confidence.

### Layer 9: Install And Update Validation

Purpose:

- Prove fresh install, app-only update, driver update, and combined update behavior before relying on user machines.

Coverage:

- Fresh install places `MixedCaptureAudio.app` and `MixedCaptureAudio.driver` in the expected locations.
- App-only update leaves the installed HAL driver untouched.
- App-only update refuses `Ready` if it requires a newer driver.
- Driver update replaces only `/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver`.
- Driver update requires installer authorization instead of a privileged background helper.
- Combined app and driver update verifies app version, driver version, shared-memory ABI, target shared-fill constant, and Core Audio visibility.
- Missing driver maps to `AudioDeviceStatus.Missing`.
- Old/incompatible driver maps to `AudioDeviceStatus.Incompatible` and `UpdateStatus.DriverUpdateRequired`.
- Installed-but-not-reloaded driver maps to `InstalledButNeedsReload` or `RestartRequired`.
- QuickTime open during driver update produces guidance rather than silent replacement.
- Capture running during attempted driver update is stopped or blocked before installer launch.
- Setup Advanced uninstall uses list-shaped confirmation copy.
- Setup Advanced uninstall discards final shared memory, disables login at startup, removes app-owned state, starts a copied uninstaller helper through an async LaunchServices handoff, records helper handoff separately from completion, and quits the main app.
- Setup Advanced uninstall preserves privacy choices, avoids re-writing preferences after state removal, and leaves normal setup recovery available after failed state removal.
- The helper finish window runs as a temporary regular Dock app under bundle identifier `com.minamiktr.mca.uninstall` with display name `Finish Uninstalling MCA`.
- The helper finish window has native Quit and Window menu commands, shows the HAL driver first and app bundle second, keeps the app row unavailable until the parent app process exits, and surfaces a wrapping manual-quit backstop after a bounded wait.
- The helper finish window prevents Close from terminating the helper while work remains, confirms incomplete Quit/Command-Q before honoring an explicit quit, reveals the real installed artifacts in Finder, and leaves privileged Trash moves to Finder/macOS authorization.
- The helper finish window shows next-step guidance while removal is in progress, checks again, then shows native bullet-row completion guidance after both installed artifacts are gone.

Acceptance:

- App never reports `Ready` with an incompatible driver.
- App never starts mixing against an unsupported shared-memory ABI or mismatched target shared-fill constant.
- App-held live mixer activity assertions begin after successful native mixer start and end on stop, failed restart, synchronous termination stop, or final shared-memory discard.
- Driver update path uses signed/notarized package installation.
- User receives clear reload/restart guidance when needed.
- Uninstall requires clear user confirmation and restart guidance when a driver was present.

Detailed update policy is documented in:

```text
/tmp/quicktime-mixed-audio-helper-update-and-installation-strategy.md
```

### Layer 10: Manual QuickTime Acceptance

Purpose:

- Prove the actual user workflow works.

Steps:

1. Install/load `MixedCaptureAudio.driver`.
2. Launch `MixedCaptureAudio.app`.
3. Complete durable setup.
4. Select a microphone if needed.
5. Open QuickTime Player.
6. Choose New Screen Recording.
7. Open Options.
8. Select `Mixed Capture Audio` as microphone.
9. Play browser/system audio.
10. Confirm the System Audio row auto-checks while the recording client is active.
11. Speak into selected mic.
12. Record 30 seconds.
13. Stop recording.
14. Play back recording.

Acceptance:

- Playback includes computer audio.
- Playback includes microphone audio.
- Audio is not obviously distorted.
- Audio remains roughly in sync over 30 seconds.
- No crash, hang, or high-noise failure.

Failure scenarios:

- Stop app mid-recording: QuickTime continues with silence, no crash/noise.
- Restart app mid-recording: audio resumes after generation resync.
- Unplug mic mid-recording: app reports degraded; system audio can continue.
- Stop system audio source: app reports degraded or silence; mic can continue.

## Long-Run And Stress Tests

Purpose:

- Catch drift, repeated underruns, overrun behavior, and lifecycle issues.

Scenarios:

- 10-minute synthetic signal through Rust -> shared memory -> HAL recorder.
- 10-minute real system audio plus mic mixing.
- 10-minute 44.1 kHz source to 48 kHz output scenario.
- 10-minute 48 kHz source to 48 kHz output scenario.
- Simulated small clock drift between system and mic sources.
- 30-60 minute producer-to-HAL shared-ring fill drift scenario.
- 30-60 minute producer-to-HAL run under CPU and timer-pressure load.
- Mixer-thread wakeup-jitter measurement under normal and loaded system conditions.
- HAL latency query while the app is stopped and shared memory does not exist.
- App/HAL ABI mismatch scenario for target shared-fill constants.
- Repeated start/stop cycles.
- App restart while HAL client is active.
- Sleep/wake while app is stopped.
- Sleep/wake while app is running.
- Output device change while app is running.
- Mic unplug/replug while app is running.

Initial thresholds:

- No crash or hang.
- No continuous underrun pattern under normal load.
- No obvious drift over 10 minutes in 44.1 kHz and 48 kHz source scenarios.
- Shared-ring fill avoids unbounded growth/shrinkage around the fixed ABI target during 30-60 minute producer-to-HAL drift tests.
- Shared-ring fill error min/max/mean/p95/p99 are recorded and stay within the chosen residual sync-error budget.
- Mixer wakeup jitter remains below the fixed target-fill budget with measured margin, or the target-fill ABI constant is raised before release.
- Under load, the mixer owner thread remains high-QoS/time-constrained and App Nap/timer coalescing is suppressed while the session is active; when idle, the owner thread demotes to utility QoS/standard policy.
- Final-stage rate trim remains within configured bounds.
- HAL-reported latency includes the fixed target shared-ring fill even when the app is stopped.
- App blocks `Ready` when app/Rust/HAL target-fill constants or ABI versions disagree.
- Clipped-frame count should remain zero at default gains for normal signals.
- HAL must always return silence rather than stale/noisy data when producer is unavailable.
- QuickTime A/V sync remains acceptable with reported HAL latency.

Refine numeric thresholds after first working prototype captures real timing data.

Before v1 ABI freeze, choose and document:

- maximum residual sync error from shared-ring fill deviation
- whether the 50 ms / 2400 frame target-fill constant remains the v1 release value

## CI Strategy

CI should run:

- Rust unit tests.
- Rust FFI layout tests.
- C shared-memory reader tests.
- Swift unit tests through `xcodebuild test`.
- Xcode build/archive for app target.
- Xcode build for HAL target.
- Header generation check with `cbindgen`.

CI should call Cargo, Xcode, and required packaging/release scripts directly. It should not hide Swift test execution behind shell wrappers, and it must not compile Swift tests directly with `swiftc`.

CI may skip:

- HAL installation.
- Core Audio reload.
- QuickTime manual tests.
- System-audio permission tests.

Those require a privileged or interactive macOS runner.

## Test Artifacts

Keep generated test artifacts in a predictable ignored directory:

```text
TestArtifacts/
  wav/
  logs/
  diagnostics/
```

Useful artifacts:

- 30-second proof WAV.
- Synthetic HAL capture WAV.
- QuickTime acceptance recording.
- Diagnostics snapshot.
- Health counter snapshot before/after tests.

Diagnostic snapshots must be metadata-only. They must not include audio buffers, recordings, transcripts, window titles, document names, or browser tabs. Full policy is documented in `/tmp/quicktime-mixed-audio-helper-diagnostics-preferences-and-privacy.md`.

## Open Items

- Confirm exact command/tool for enumerating Core Audio devices in automated HAL property tests.
- Confirm direct POSIX shared-memory access from sandboxed `coreaudiod`, or prove/reject fallback setup.
- Define final source-rate, ASRC, and drift thresholds after prototype data.
- Confirm system audio TCC reset behavior on target macOS versions.
- Define final numeric thresholds for acceptable underrun frequency and drift after prototype data.
- Decide whether QuickTime acceptance should remain manual or be partially automated with a dedicated recorder tool.
- Confirm exact Sparkle package-update behavior for signed/notarized driver installer packages.
- Define exact driver owner/group/permission expectations during implementation.

The evidence matrix for these remaining confirmations is documented in `/tmp/quicktime-mixed-audio-helper-remaining-confirmations.md`.
