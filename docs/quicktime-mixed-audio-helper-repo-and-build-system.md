# QuickTime MixedCaptureAudio Repo And Build System

## Summary

Xcode is the top-level build owner for Apple artifacts. Cargo builds the Rust audio engine. Xcode invokes Cargo and `cbindgen` through explicit build targets/scripts, then links the generated Rust static library into the Swift app. The HAL plug-in is a C `.driver` bundle and does not link the Rust mixer engine in v1.

Core decision:

```text
Xcode owns app, HAL plug-in, signing, packaging, and release orchestration.
Cargo owns Rust compilation and Rust tests.
cbindgen owns the generated C ABI header.
lipo is used only when producing a universal Rust static library.
```

The app, Rust engine, and HAL plug-in must share the same ABI constants for output format, shared-memory version, and target shared-fill latency. Keep those constants in one generated or mechanically verified header, and fail CI if Swift/Rust/C copies diverge.

## Repository Layout

```text
  MixedCaptureAudio/
  MixedCaptureAudio.xcworkspace
  MixedCaptureAudio.xcodeproj

  App/
    Sources/
      MixedCaptureAudioApp.swift
      Session/
      Permissions/
      Devices/
      Diagnostics/
      Preferences/
      RustBridge/
    Resources/
      Info.plist
      Assets.xcassets
    MixedCaptureAudio.entitlements

  HALPlugin/
    Sources/
      MixedCaptureAudioDriver.c
      MixedAudioSharedMemoryReader.c
    Include/
      MixedAudioSharedMemory.h
    Resources/
      Info.plist

  Rust/
    mixed-audio-engine/
      Cargo.toml
      cbindgen.toml
      src/
        lib.rs
        ffi.rs
        mixer.rs
        shared_memory_writer.rs
        health.rs
      tests/

  Generated/
    include/
      mixed_audio_engine.h
    lib/
      debug/
      release/

  Scripts/
    build-rust.sh
    generate-rust-header.sh
    install-hal-driver.sh
    uninstall-hal-driver.sh
    package-release.sh
    package-driver-update.sh
    notarize-release.sh

  Docs/
```

`Generated/` may be ignored by git if the project prefers reproducible generated artifacts. If generated headers are checked in for IDE convenience, CI must verify they match `cbindgen` output.

## Xcode Targets

### `MixedCaptureAudio.app`

Swift menu-bar app target.

Responsibilities:

- SwiftUI/AppKit UI.
- Permission prompts and diagnostics.
- Core Audio process tap setup.
- Selected microphone input setup.
- Session lifecycle.
- Calls Rust audio engine through generated C ABI.
- Creates/writes POSIX shared memory through Rust engine APIs.

Links:

- `CoreAudio.framework`
- `AVFoundation.framework` if used for mic/session helpers
- `AppKit.framework`
- `SwiftUI.framework`
- `libmixed_audio_engine.a`

Includes:

- `Generated/include/mixed_audio_engine.h`
- `HALPlugin/Include/MixedAudioSharedMemory.h` if the app reads shared-memory health directly.

Required app metadata:

- `NSMicrophoneUsageDescription`
- `NSAudioCaptureUsageDescription`
- Bundle identifier: `com.minamiktr.mca`
- Developer ID signing for distribution.
- Hardened runtime for notarized release builds.

### `MixedCaptureAudio.driver`

C HAL AudioServerPlugIn bundle target.

Responsibilities:

- Expose one virtual input device named `Mixed Capture Audio`.
- Advertise one stereo 48 kHz Float32 input stream for v1.
- Open/map POSIX shared memory if available.
- Read mixed frames without blocking.
- Silence-fill missing/stale/invalid/underrun data.

Links:

- `CoreAudio.framework`

Includes:

- `HALPlugin/Include/MixedAudioSharedMemory.h`

Does not link:

- Rust mixer static library.
- Swift app code.
- Objective-C/Swift UI/runtime layers.

### `RustAudioEngine`

Xcode aggregate or external-build target that runs the Rust build scripts.

Responsibilities:

- Run `cbindgen`.
- Run `cargo build`.
- Produce architecture-specific or universal `libmixed_audio_engine.a`.
- Place outputs in `Generated/include` and `Generated/lib`.

`MixedCaptureAudio.app` depends on this target.

### Test Targets

Recommended targets:

- Swift unit-test target for app services, permissions state mapping, diagnostics, and session state.
- Swift unit-test target coverage for preferences defaults, migration, and diagnostic export privacy.
- Rust tests run through `cargo test`.
- C shared-memory reader test target or small command-line tool for HAL transport behavior.

## Rust Crate

Recommended crate type:

```toml
[lib]
crate-type = ["staticlib"]
```

Recommended release profile:

```toml
[profile.release]
panic = "abort"
lto = true
codegen-units = 1
```

`panic = "abort"` is intentional for release. FFI entry points still validate inputs
and may use `catch_unwind` in unwind-capable debug/test builds, but a release Rust
panic is treated as a fatal engine bug rather than a recoverable host-app error.

Rust outputs:

```text
Generated/include/mixed_audio_engine.h
Generated/lib/debug/libmixed_audio_engine.a
Generated/lib/release/libmixed_audio_engine.a
```

For release universal builds, `Generated/lib/release/libmixed_audio_engine.a` is the `lipo`-merged universal library.

## What `lipo` Does

`lipo` is Apple’s tool for creating a universal Mach-O binary or library. A universal artifact contains multiple architecture slices in one file, commonly:

```text
arm64 + x86_64
```

Xcode already does this for native Swift and C targets. Cargo does not. Cargo builds one Rust target triple at a time:

```text
aarch64-apple-darwin
x86_64-apple-darwin
```

For universal release builds, `build-rust.sh` runs Cargo for both targets and uses `lipo -create` to merge the two Rust static libraries into one file for Xcode to link.

For local debug builds, skip `lipo` and build only the active architecture.

## Build Ownership

Xcode should own the overall build graph:

```text
RustAudioEngine target
  -> Scripts/generate-rust-header.sh
  -> Scripts/build-rust.sh
  -> Generated/include/mixed_audio_engine.h
  -> Generated/lib/<configuration>/libmixed_audio_engine.a

MixedCaptureAudio.app target
  -> depends on RustAudioEngine
  -> links Generated/lib/<configuration>/libmixed_audio_engine.a

MixedCaptureAudio.driver target
  -> builds C HAL plug-in
  -> links CoreAudio.framework only
```

Scripts exist because Cargo and `cbindgen` are external tools, not because they own the product build. Keep scripts small, deterministic, and callable both from Xcode and terminal.

## Debug Build Flow

Debug builds optimize for fast local iteration.

1. Xcode builds active architecture only.
2. `RustAudioEngine` runs `cbindgen` and verifies shared ABI constants.
3. `RustAudioEngine` runs `cargo build` for the active architecture.
4. Xcode links the active-architecture Rust static library into `MixedCaptureAudio.app`.
5. Xcode builds `MixedCaptureAudio.driver`.
6. Developer installs or reinstalls the HAL driver manually with `Scripts/install-hal-driver.sh`.

Do not require universal Rust output for normal local debug builds.

## Release Build Flow

Release builds optimize for distributable artifacts.

1. Run Rust tests with `cargo test`.
2. Run Swift and C tests from Xcode.
3. Generate Rust C ABI header with `cbindgen`.
4. Build Rust for `aarch64-apple-darwin`.
5. Build Rust for `x86_64-apple-darwin`.
6. Merge Rust static libraries with `lipo`.
7. Archive `MixedCaptureAudio.app`.
8. Build `MixedCaptureAudio.driver`.
9. Sign app and HAL driver.
10. Package installer/DMG/PKG.
11. Notarize package.
12. Staple notarization ticket where applicable.

Release packaging must distinguish app-only updates from driver updates:

- App-only update: update `MixedCaptureAudio.app`; do not reinstall the HAL driver.
- Driver update: ship a signed and notarized package installer that installs/replaces `MixedCaptureAudio.driver`.
- Combined update: package app and driver together when their versions must move in lockstep.

Detailed update policy belongs in:

```text
/tmp/quicktime-mixed-audio-helper-update-and-installation-strategy.md
```

## HAL Driver Installation

Install location:

```text
/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver
```

Development install script:

```text
Scripts/install-hal-driver.sh
```

Development uninstall script:

```text
Scripts/uninstall-hal-driver.sh
```

Installer responsibilities:

- Copy the signed `.driver` bundle into `/Library/Audio/Plug-Ins/HAL`.
- Set ownership and permissions appropriate for system plug-ins.
- Avoid force-restarting Core Audio without explicit developer/user intent.
- Tell the user when logout/restart/Core Audio reload is required.
- Preserve stable bundle identifiers and driver/device identity.
- Leave enough installed metadata for the app to verify driver version, shared-memory ABI compatibility, output format, and target shared-fill constant.

Uninstaller responsibilities:

- Remove `/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver`.
- Remove app-owned support files if requested.
- Leave unrelated HAL plug-ins untouched.

## HAL Bundle Notes

The HAL plug-in is a bundle with `.driver` extension and an `Info.plist`. It must provide the Core Audio server plug-in factory metadata expected by Core Audio and return an `AudioServerPlugInDriverInterface`.

The detailed HAL object model belongs in:

```text
/tmp/quicktime-mixed-audio-helper-hal-plugin-spec.md
```

The detailed app and HAL plist requirements belong in:

```text
/tmp/quicktime-mixed-audio-helper-plist-requirements.md
```

The detailed update and installer strategy belongs in:

```text
/tmp/quicktime-mixed-audio-helper-update-and-installation-strategy.md
```

Remaining install, signing, package-update, and reload confirmations belong in:

```text
/tmp/quicktime-mixed-audio-helper-remaining-confirmations.md
```

This build doc only requires:

- C bundle target.
- `CoreAudio.framework` link.
- `.driver` product.
- install path under `/Library/Audio/Plug-Ins/HAL`.
- signing/notarization included in release packaging.

## Script Contracts

### `Scripts/generate-rust-header.sh`

Inputs:

- `Rust/mixed-audio-engine/cbindgen.toml`
- Rust crate source files.

Output:

- `Generated/include/mixed_audio_engine.h`

Behavior:

- Run `cbindgen`.
- Fail if the generated header is empty or invalid.
- In CI, compare checked-in header if the project chooses to commit generated headers.

### `Scripts/build-rust.sh`

Inputs:

- Build configuration: Debug or Release.
- Active architecture for debug.
- Universal flag for release.

Outputs:

- `Generated/lib/debug/libmixed_audio_engine.a`
- `Generated/lib/release/libmixed_audio_engine.a`

Behavior:

- Debug: build only active architecture.
- Release: build both `aarch64-apple-darwin` and `x86_64-apple-darwin`, then merge with `lipo`.
- Fail clearly if Cargo, Rust targets, `cbindgen`, or `lipo` are unavailable.

### `Scripts/install-hal-driver.sh`

Inputs:

- Built `MixedCaptureAudio.driver` path.

Output:

- Installed driver under `/Library/Audio/Plug-Ins/HAL`.

Behavior:

- Require administrator privileges.
- Copy bundle.
- Preserve signing.
- Print reload/restart instructions.

### `Scripts/uninstall-hal-driver.sh`

Inputs:

- Installed driver path.

Behavior:

- Require administrator privileges.
- Remove only this project’s driver bundle.
- Print reload/restart instructions.

### `Scripts/package-driver-update.sh`

Inputs:

- Signed `MixedCaptureAudio.driver`.
- Driver version.
- Shared-memory ABI version.
- Fixed target shared-fill ABI constant.

Output:

- Signed/notarized package installer for driver updates.

Behavior:

- Build a package payload that installs only this project’s HAL driver.
- Set owner/group/permissions appropriate for `/Library/Audio/Plug-Ins/HAL`.
- Include version metadata the app can verify after installation.
- Avoid adding a privileged background helper in v1.

## CI Expectations

CI should run:

- `cargo test`
- `cbindgen` header generation check
- Shared ABI constant consistency check
- Xcode build for app target
- Xcode build for HAL target
- Xcode unit tests
- C shared-memory reader tests
- Diagnostics/preferences privacy tests
- Release packaging dry-run, where certificates are available.
- App/driver version manifest validation.

CI may skip actual HAL installation unless running on a privileged macOS runner. HAL installation and QuickTime manual recording remain manual or dedicated hardware-runner tests.

## Open Follow-Up Items

- Confirm exact CFPlugIn UUID values and plist shape during HAL implementation.
- Confirm direct POSIX shared-memory access from sandboxed `coreaudiod`, or implement the documented fallback path.
- Confirm exact Sparkle package-update behavior for driver installer packages.
- Confirm exact owner/group/permission values for the installed HAL driver.
- Confirm exact Core Audio reload/restart detection behavior after the first HAL prototype.

The confirmation matrix for these items is documented in `/tmp/quicktime-mixed-audio-helper-remaining-confirmations.md`.

## References

- Apple universal binary guidance: [Building a universal macOS binary](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary)
- Apple Xcode build scripts: [Running custom scripts during a build](https://developer.apple.com/documentation/xcode/running-custom-scripts-during-a-build)
- Apple Audio Server Driver Plug-in guide: [Creating an audio server driver plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- Apple AudioServerPlugIn interface: [AudioServerPlugInDriverInterface](https://developer.apple.com/documentation/coreaudio/audioserverplugindriverinterface)
- Apple Core Audio taps: [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- Sparkle documentation: [Documentation](https://sparkle-project.github.io/documentation/)
- Apple notarization: [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
