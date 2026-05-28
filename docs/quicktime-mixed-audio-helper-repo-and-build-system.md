# QuickTime MixedCaptureAudio Repo And Build System

## Summary

Xcode is the top-level build owner for Apple artifacts. Cargo builds the Rust audio engine. Xcode invokes Cargo and `cbindgen` through explicit build targets/scripts, then links the generated Rust static library into the Swift app. XCTest is the test framework for Swift/AppKit/SwiftUI code. The HAL plug-in is a C `.driver` bundle and does not link the Rust mixer engine in v1.

Core decision:

```text
Xcode owns app, HAL plug-in, Swift unit tests, signing, packaging, and release orchestration.
XCTest owns Swift/AppKit/SwiftUI unit tests.
Cargo owns Rust compilation and Rust tests.
cbindgen owns the generated C ABI header.
lipo is used only when producing a universal Rust static library.
```

Direct `swiftc` app builds and standalone Swift test executables are not the project standard. The app now has a native Xcode application target, and Swift app tests are native XCTest cases.

The app, Rust engine, and HAL plug-in must share the same ABI constants for output format, shared-memory version, and target shared-fill latency. Keep those constants in one generated or mechanically verified header, and fail CI if Swift/Rust/C copies diverge.

## Repository Layout

```text
  MixedCaptureAudio/
  MixedCaptureAudio.xcworkspace
  MixedCaptureAudio.xcodeproj

  App/
    Sources/
      App/
      Audio/
      Diagnostics/
      SystemAudio/
    Resources/
      Info.plist
      Assets.xcassets
    MixedCaptureAudio.entitlements

  AppTests/
    MixedCaptureAudioTests/

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
    build-rust-engine.sh
    generate-rust-shared-memory-abi.sh
    manage-installation.sh
    build-package.sh

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
- `CoreFoundation.framework`
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

Build:

- Native Xcode bundle target.
- Product: `MixedCaptureAudio.driver`.
- Info.plist: `HALPlugin/Resources/Info.plist`.

Does not link:

- Rust mixer static library.
- Swift app code.
- Objective-C/Swift UI/runtime layers.

### `MixedCaptureAudioApp`

Native Xcode macOS application target.

Responsibilities:

- Compile Swift app sources.
- Compile Objective-C bridge/probe sources.
- Own app Info.plist and entitlements.
- Link AppKit, SwiftUI, AVFoundation, CoreAudio, AudioToolbox, ServiceManagement, and Foundation.
- Invoke the Rust boundary build phase and link `Generated/lib/<profile>/libmixed_audio_engine.a`.

### `RustAudioEngine`

Xcode aggregate or external-build target that runs the Rust build scripts.

Responsibilities:

- Run `cbindgen`.
- Run `cargo build`.
- Produce architecture-specific or universal `libmixed_audio_engine.a`.
- Place outputs in `Generated/include` and `Generated/lib`.

`MixedCaptureAudio.app` depends on this target.

### Test Targets

Required targets:

- `MixedCaptureAudioTests`: app-hosted XCTest unit-test bundle for app services, permissions state mapping, diagnostics, presentation, preferences, and session state.
- XCTest coverage for preferences defaults, migration, diagnostic export privacy, selected-app source behavior, setup presentation, and command/menu behavior.
- Rust tests run through `cargo test`.
- C shared-memory reader test target or small command-line tool for HAL transport behavior.

Swift tests must be discoverable and runnable through Xcode and `xcodebuild test`. New Swift app tests should not be added as custom `@main` executables. App tests import the Debug app module with `@testable import MixedCaptureAudio`; the test target must not compile duplicate copies of app sources.

## Dependency Management

Use Apple-native dependency declarations for Apple code:

- System frameworks live in Xcode target settings.
- Swift packages, if introduced, are declared in the Xcode project/workspace through Swift Package Manager.
- App target membership, resources, entitlements, Info.plist files, and test bundles are modeled in Xcode.
- Rust dependencies remain in `Cargo.toml`.
- Generated Rust headers and static libraries are external artifacts consumed by Xcode targets.

Do not add custom shell dependency resolution for Swift packages or app frameworks.

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

For universal release builds, the Rust/Xcode boundary should run Cargo for both targets and use `lipo -create` to merge the two Rust static libraries into one file for Xcode to link.

For local debug builds, skip `lipo` and build only the active architecture.

## Build Ownership

Xcode should own the overall build graph:

```text
RustAudioEngine target
  -> Scripts/generate-rust-shared-memory-abi.sh
  -> Scripts/build-rust-engine.sh
  -> Generated/include/MixedAudioEngine.h
  -> Generated/lib/<configuration>/libmixed_audio_engine.a

MixedCaptureAudio.app target
  -> depends on RustAudioEngine
  -> links Generated/lib/<configuration>/libmixed_audio_engine.a

MixedCaptureAudioTests target
  -> app-hosted XCTest bundle
  -> depends on MixedCaptureAudio.app
  -> @testable imports MixedCaptureAudio

MixedCaptureAudio.driver target
  -> builds C HAL plug-in
  -> links CoreAudio.framework only
```

Scripts exist only where the work cannot reasonably live in Xcode, Cargo, SwiftPM, GitHub Actions, or the native Apple tool being used. Cargo/ABI generation, packaging, signing, notarization, installation, uninstall, and Core Audio reload are valid integration seams. Manual proof scripts and support-only builder scripts are not part of the project surface.

Scripts must not own Swift app compilation or Swift unit-test execution once the native target graph exists. Keep the remaining scripts small, deterministic, and callable both from Xcode and terminal.

## Debug Build Flow

Debug builds optimize for fast local iteration.

1. Xcode builds active architecture only.
2. `RustAudioEngine` runs `cbindgen` and verifies shared ABI constants.
3. `RustAudioEngine` runs `cargo build` for the active architecture.
4. Xcode links the active-architecture Rust static library into `MixedCaptureAudio.app`.
5. Xcode runs `MixedCaptureAudioTests` through XCTest.
6. Xcode builds `MixedCaptureAudio.driver`.
7. Developer installs or reinstalls the HAL driver manually with `Scripts/manage-installation.sh install-driver`.

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

Development install command:

```text
Scripts/manage-installation.sh install-driver
```

Development uninstall command:

```text
Scripts/manage-installation.sh uninstall-driver
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

Only active product-plumbing scripts should exist.

### `Scripts/generate-rust-shared-memory-abi.sh`

Input:

- `HALPlugin/Include/MixedAudioSharedMemory.h`

Output:

- `Rust/mixed-audio-engine/src/generated_shared_memory_abi.rs`

Behavior:

- Mirror shared-memory constants into Rust.
- Support `--check` so CI can fail when the generated Rust mirror is stale.

### `Scripts/build-rust-engine.sh`

Inputs:

- Build configuration: Debug or Release through `CONFIGURATION`.

Outputs:

- `Generated/lib/debug/libmixed_audio_engine.a`
- `Generated/lib/release/libmixed_audio_engine.a`
- `Generated/include/MixedAudioEngine.h`

Behavior:

- Regenerate/check the shared-memory ABI mirror.
- In Debug, run Cargo once for the active host architecture.
- In Release, build both `aarch64-apple-darwin` and `x86_64-apple-darwin`, then merge the static libraries with `lipo`.
- Copy the generated Rust static library and C ABI header into `Generated/`.

### `Scripts/manage-installation.sh`

Inputs:

- Built `MixedCaptureAudio.driver` path.

Output:

- Installed driver under `/Library/Audio/Plug-Ins/HAL`.

Behavior:

- `install-driver [driver-path]` requires administrator privileges, copies the bundle, preserves signing, and prints reload/restart instructions.
- `uninstall-driver` removes only this project’s driver bundle.
- `reload-coreaudio` restarts Core Audio driver hosts for local development.
- `uninstall` removes the installed app and driver while preserving preferences and privacy permission records.

### `Scripts/build-package.sh`

Inputs:

- Built or buildable app and HAL driver.
- Optional `--sign`.
- Optional `--notarize`, which implies `--sign`.

Output:

- Package installer containing the app and HAL driver.

Behavior:

- Build a package payload that installs this project’s app and HAL driver.
- Starting with version `0.2.x`, release `.pkg` installers support universal macOS architecture.
- Use Xcode's generic macOS destination for Release package builds so Xcode emits universal native products instead of a host-specific `My Mac` build.
- Keep non-Release package builds host-architecture focused unless `XCODE_DESTINATION` is explicitly set.
- Reject Release package builds unless the app executable, HAL driver executable, generated Rust static library, and packaged payload executables contain both `arm64` and `x86_64` slices.
- Set owner/group/permissions appropriate for `/Library/Audio/Plug-Ins/HAL`.
- Reject relocatable bundle metadata.
- With `--sign`, import Developer ID signing identities into a temporary keychain, sign the app, HAL driver, and package, then restore keychain state on exit.
- With `--notarize`, submit the signed package through `notarytool`, staple, and validate the accepted package.

## CI Expectations

CI should run:

- `cargo test`
- `cbindgen` header generation check
- Shared ABI constant consistency check
- `xcodebuild test` for `MixedCaptureAudioTests`
- `xcodebuild build` for `MixedCaptureAudioApp`
- `xcodebuild build` for `MixedCaptureAudioDriver`
- unsigned installer package build
- Release packaging dry-run, where certificates are available.
- App/driver version validation.

CI may skip actual HAL installation unless running on a privileged macOS runner. HAL installation and QuickTime manual recording remain manual or dedicated hardware-runner tests.

CI should call Cargo, Xcode, and the few required packaging/release scripts directly. It should not hide native build/test commands behind shell wrappers.

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
