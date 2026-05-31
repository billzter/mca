# MixedCaptureAudio Update And Installation Strategy

## Summary

`MixedCaptureAudio` has two installed artifacts:

```text
/Applications/MixedCaptureAudio.app
/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver
```

The app can update like a normal macOS app. The HAL driver cannot be treated as an ordinary app resource because Core Audio discovers it from the system HAL plug-ins directory and may keep it loaded while audio clients are active.

V1 should use a simple hybrid strategy:

- Use a signed app updater for app-only updates.
- Use a signed and notarized package installer for any update that installs, replaces, or removes the HAL driver.
- Do not ship a privileged background helper in v1.

## Goals

- Keep the update path understandable for users.
- Avoid hidden privileged background behavior.
- Preserve stable bundle identifiers and device identifiers.
- Prevent app/driver ABI mismatches.
- Make driver update requirements visible in onboarding, settings, and diagnostics.
- Keep release packaging compatible with Developer ID signing and notarization.

## Non-Goals For V1

V1 does not include:

- Privileged background update helper.
- Silent driver replacement.
- Automatic Core Audio restart.
- Driver updates while recording is active.
- Multiple installed driver variants.
- Per-app audio update policy.

## Stable Identity

These identifiers should remain stable once shipped:

```text
App bundle identifier:
com.minamiktr.mca

HAL driver bundle identifier:
com.minamiktr.mca.driver

Device UID:
com.minamiktr.mca.device.MixedCaptureAudio

Model UID:
com.minamiktr.mca.model.MixedCaptureAudio

Shared-memory object name:
/mca.mix.v1
```

Do not change these identifiers for normal releases. Changing them can break permissions, user preferences, QuickTime device selection, update discovery, and driver/app compatibility checks.

## Version Contract

The app must know which driver and shared-memory ABI versions it can use.

Recommended version fields:

```text
App CFBundleShortVersionString
App CFBundleVersion
HAL CFBundleShortVersionString
HAL CFBundleVersion
SharedMemoryAbiVersion
MinimumCompatibleDriverVersion
MaximumCompatibleDriverVersion
RequiredDriverVersion
```

Recommended runtime compatibility check:

```text
driver installed?
driver bundle identifier == com.minamiktr.mca.driver?
driver version in supported range?
shared-memory ABI version supported?
target shared-fill ABI constant matches app/Rust expectation?
Core Audio device visible?
driver reload/restart needed?
```

If the shared-memory layout, output format, or fixed target shared-fill constant changes incompatibly, either:

- increment the shared-memory ABI and require a compatible driver update, or
- move to a new shared-memory object suffix such as `.v2`.

Do not reuse `/mca.mix.v1` for an incompatible layout.

## Update Types

### App-Only Update

Use this for:

- Swift UI changes.
- Permission/onboarding copy changes.
- Diagnostics changes.
- Rust mixer changes that do not alter the shared-memory ABI.
- App-side bug fixes.
- App-side capture behavior changes.

Expected behavior:

- No admin authorization.
- No HAL reinstall.
- No Core Audio reload.
- Existing microphone/system-audio permissions should remain associated with `com.minamiktr.mca`.

Recommended updater:

- Sparkle 2 or equivalent signed updater.

Release artifact:

```text
MixedCaptureAudio.app update archive
```

### Driver Update

Use this for:

- HAL driver C code changes.
- HAL `Info.plist` changes.
- Driver signing changes.
- Device UID/model UID changes, if ever unavoidable.
- Shared-memory ABI changes.
- Shared-memory reader changes that require driver replacement.
- Driver install path or permissions changes.

Expected behavior:

- Stop active capture/mixing before install.
- Ask user to close QuickTime and other recording clients if needed.
- Require administrator authorization through the installer.
- Replace `/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver`.
- Show reload/restart guidance after installation.

Release artifact:

```text
Signed and notarized .pkg installer
```

### Combined App And Driver Update

Use this when app and driver must move together.

Expected behavior:

- Prefer one signed/notarized package installer containing both the app and HAL driver.
- The app should mark the old driver as incompatible before starting capture.
- After install, the app should re-check app version, driver version, shared-memory ABI, target shared-fill constant, and device visibility.

## Recommended Update Mechanism

Use Sparkle or an equivalent updater for app-only updates.

For driver updates, use a package installer instead of a privileged helper in v1. The package installer should be signed with a Developer ID Installer identity and notarized.

Rationale:

- The HAL driver lives in a system-owned location.
- Replacing it requires administrator-level installation.
- A package installer makes authorization, file ownership, payload contents, and auditability clear.
- Avoiding a privileged helper reduces security and support surface in v1.

Sparkle can be considered as the discovery and delivery mechanism for both app-only and package updates, but the implementation must verify package-update behavior against the chosen Sparkle version during prototyping.

## App Startup Checks

On launch, the app should check:

```text
Installed app version
Expected driver version
Installed driver bundle path
Installed driver bundle identifier
Installed driver version
Installed driver code signature status, future optional
Shared-memory ABI compatibility
Target shared-fill constant compatibility
Core Audio device visibility
Whether a reload/restart appears required
```

The app should not claim `Ready` unless the installed driver is compatible.

## Update State Model

Use PascalCase state names.

`UpdateStatus`:

```text
Unknown
Current
AppUpdateAvailable
DriverUpdateAvailable
DriverUpdateRequired
CombinedUpdateAvailable
Installing
InstalledButNeedsReload
RestartRequired
Failed
```

Rules:

- `Current`: app and driver are compatible and no known update is required.
- `AppUpdateAvailable`: app can update without touching the HAL driver.
- `DriverUpdateAvailable`: driver update is available but not required for current app compatibility.
- `DriverUpdateRequired`: installed driver is missing or incompatible.
- `CombinedUpdateAvailable`: app and driver should be updated together.
- `Installing`: user has started an update/install flow.
- `InstalledButNeedsReload`: files are installed but Core Audio has not picked up the driver state.
- `RestartRequired`: the safest next action is user logout/restart or Mac restart.
- `Failed`: update/install status could not be completed or verified.

## User Flow For Driver Update

1. App detects missing, old, or incompatible driver.
2. App shows `DriverUpdateRequired`.
3. User clicks `Install Update` or `Update Audio Device`.
4. App stops capture/mixing if running.
5. App asks user to close QuickTime or other active recording clients if needed.
6. App launches the signed/notarized package installer.
7. Installer replaces the HAL driver and sets correct ownership/permissions.
8. User returns to the app.
9. App re-checks driver installation and Core Audio visibility.
10. If the driver is installed but not loaded, app shows reload/restart guidance.

Do not force-kill Core Audio in v1. Developer scripts may support explicit reload during development, but the user-facing flow should prefer clear guidance.

## User Flow For App-Only Update

1. Updater detects a new app-only version.
2. User approves update, or automatic app updates run if the user enabled them.
3. App stops capture/mixing if required by the updater.
4. Updater replaces the app.
5. Relaunched app verifies installed driver compatibility before claiming `Ready`.

The app must still refuse to start mixing if an app-only update introduces a new required driver version and the driver was not updated.

## Installer Responsibilities

Package installer responsibilities:

- Install `MixedCaptureAudio.app` to `/Applications` when included.
- Install `MixedCaptureAudio.driver` to `/Library/Audio/Plug-Ins/HAL`.
- Preserve code signatures.
- Set system-appropriate owner, group, and permissions.
- Avoid changing unrelated HAL plug-ins.
- Avoid removing user preferences unless this is an explicit uninstall flow.
- Leave a clear result for the app to verify after install.

The installer should not:

- Start capture.
- Modify unrelated audio devices.
- Force-kill Core Audio without explicit user/admin intent.
- Reset TCC permissions.

## Uninstall Strategy

V1 provides an explicit in-app uninstall path from the Setup window's Advanced section. The status menu should keep setup and quit actions only; destructive uninstall actions belong in Setup where the app can explain scope and recovery.

The uninstall flow should:

- Stop the live mixer and discard `/mca.mix.v1` so the HAL driver reads silence instead of stale frames.
- Disable the login item.
- Remove app-owned preferences, support files, caches, diagnostics, and temporary lock files.
- Leave setup recovery available if app-owned state removal fails.
- Copy the bundled uninstaller helper from `MixedCaptureAudio.app/Contents/Helpers/MixedCaptureAudioUninstaller.app` into a unique per-user temporary directory.
- Start the copied `.app` through an async LaunchServices handoff with a manifest, then quit the main app.
- Open a helper-owned Finish Uninstalling window for privileged installed artifacts.
- Run the helper as a temporary regular Dock app under bundle identifier `com.minamiktr.mca.uninstall`.
- Provide native Quit and Window menu commands.
- Wait for the parent app process before enabling the app row.
- Surface a wrapping manual-quit backstop after a bounded wait.
- Prevent Close from terminating the helper while work remains.
- Confirm incomplete Quit/Command-Q before honoring an explicit quit.
- Show `/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver` before `/Applications/MixedCaptureAudio.app`, because the driver can be moved while the main app is still finishing shutdown.
- Keep the app-bundle row unavailable until the manifest's parent process identifier no longer exists.
- Reveal the real installed items in Finder from that window so the user moves them to Trash.
- Let Finder/macOS own administrator authorization prompts for those privileged moves.
- Provide `Check Again` in the finish window.
- Show next-step guidance while removal is in progress.
- Replace next-step guidance with final completion guidance when both installed artifacts are gone.
- Include restart guidance when the driver was present, because Core Audio may keep the removed HAL bundle loaded until restart.

Uninstall should not reset microphone/system-audio privacy decisions automatically. Provide manual instructions if the user wants to remove TCC entries.

Preferences and diagnostics storage policy is documented in `/tmp/quicktime-mixed-audio-helper-diagnostics-preferences-and-privacy.md`.

## Release Packaging

Recommended release artifacts:

```text
App-only update archive
Full installer package
Full installer disk image, optional
```

Release signing/notarization expectations:

- Sign the app with Developer ID Application.
- Sign the HAL driver bundle with the appropriate Developer ID signing identity.
- Sign installer packages with Developer ID Installer.
- Enable hardened runtime where applicable.
- Notarize the distributed artifact.
- Staple notarization tickets where applicable.

Release automation should produce a manifest showing:

```text
app version
driver version
shared-memory ABI version
target shared-fill ABI constant
minimum compatible driver version
maximum compatible driver version
release artifact hashes
notarization result
```

## Testing

Update tests should cover:

- Fresh install.
- App-only update with compatible driver.
- App update that requires newer driver.
- Driver update with app already installed.
- Combined app and driver update.
- Downgrade attempt, if supported or explicitly blocked.
- Missing driver.
- Wrong bundle identifier at driver path.
- Corrupt or unsigned driver at driver path.
- Installed driver but Core Audio has not reloaded it.
- QuickTime open during driver update.
- App running during app-only update.
- Capture running during attempted driver update.

Acceptance:

- App never reports `Ready` with an incompatible driver.
- App never starts mixing against an unsupported shared-memory ABI or mismatched target shared-fill constant.
- Driver update path asks for authorization through the installer, not through a hidden privileged helper.
- User receives clear reload/restart guidance when needed.

## Open Items

- Confirm exact Sparkle package-update behavior for signed/notarized package installers in the chosen Sparkle version.
- Decide whether app-only updates are automatic by default or manual by default.
- Decide whether the first public release ships only as a full installer package, with Sparkle added after the install/update path is tested.
- Define exact owner/group/permission values for `MixedCaptureAudio.driver` during implementation.
- Define exact reload/restart detection logic after the first HAL prototype.
- Confirm whether fallback Mach/XPC setup changes installer/helper requirements if POSIX shared memory is blocked.

The evidence matrix for these remaining confirmations is documented in `/tmp/quicktime-mixed-audio-helper-remaining-confirmations.md`.

## References

- Sparkle documentation: [Documentation](https://sparkle-project.github.io/documentation/)
- Sparkle package updates: [Package Updates](https://sparkle-project.github.io/documentation/package-updates/)
- Apple Developer ID: [Developer ID](https://developer.apple.com/support/developer-id/)
- Apple notarization: [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- Apple packaging: [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
