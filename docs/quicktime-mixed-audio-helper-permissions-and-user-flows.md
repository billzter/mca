# QuickTime MixedCaptureAudio Permissions And User Flows

## Summary

The app must guide users through all prerequisites before they can reliably use `Mixed Capture Audio` in QuickTime. Permissions and installation state should be explicit, visible, and recoverable.

V1 prerequisites:

- HAL virtual audio device installed and loaded.
- HAL virtual audio device version compatible with the app.
- Microphone permission granted.
- System audio access test passes.
- Selected microphone available.
- Mixer/session healthy.
- QuickTime can see `Mixed Capture Audio`.

Do not start mic/system capture invisibly. The app should show a clear state whenever it is preparing, capturing, mixing, degraded, or stopped.

`MixedCaptureAudio` does not record or store audio. It creates a live mixed input that QuickTime or another recording app may record when the user chooses.

## macOS Permission Model

macOS protects sensitive capabilities through TCC: Transparency, Consent, and Control. The app needs privacy usage descriptions in `Info.plist`, and macOS presents system-controlled prompts when the app first requests access.

The app cannot grant permissions itself. It can:

- Explain why access is needed.
- Trigger the system prompt through the relevant API.
- Detect granted/denied states where APIs allow it.
- Guide users to System Settings when permission is denied or requires manual changes.
- Re-check after the user changes settings.

## Required App Metadata

`MixedCaptureAudio.app` must include:

```text
NSMicrophoneUsageDescription
NSAudioCaptureUsageDescription
```

Recommended copy:

```text
NSMicrophoneUsageDescription:
MixedCaptureAudio needs microphone access to include your selected mic in the virtual QuickTime input.

NSAudioCaptureUsageDescription:
MixedCaptureAudio needs system audio access to include computer audio in the virtual QuickTime input.
```

The app bundle identifier is `com.minamiktr.mca`. Full plist requirements are documented in `/tmp/quicktime-mixed-audio-helper-plist-requirements.md`.

Release builds should use Developer ID signing and hardened runtime. Any required entitlements should be documented in the repo/build-system doc once confirmed during implementation.

## HAL Driver Install State

HAL driver installation is not a TCC permission. It is a system install prerequisite because the `.driver` bundle lives under:

```text
/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver
```

The onboarding flow should treat the driver as a first-class prerequisite.

`AudioDeviceStatus`:

```text
Unknown
Missing
Installed
InstalledButNeedsReload
Incompatible
Failed
```

Behavior:

- `Missing`: show install action.
- `Installed`: continue.
- `InstalledButNeedsReload`: explain restart/reload requirement.
- `Incompatible`: show driver update action and prevent `Ready`. This includes mismatched app/HAL ABI version, output format, or target shared-fill constant.
- `Failed`: show diagnostics and reinstall/uninstall guidance.

The app should not automatically kill/restart Core Audio in v1. Developer scripts may support reload with explicit confirmation.

Driver update policy is documented in `/tmp/quicktime-mixed-audio-helper-update-and-installation-strategy.md`. V1 should use a signed/notarized package installer for driver updates and should not include a privileged background update helper.

## Permission Status Model

Use PascalCase state names in docs and user-facing diagnostics.

Generic `PermissionStatus`:

```text
Unknown
NotDetermined
Requesting
Granted
Denied
Restricted
Failed
```

`Unknown`:

- App has not checked yet.

`NotDetermined`:

- macOS has not asked the user yet.

`Requesting`:

- App triggered the macOS prompt and is awaiting a result.

`Granted`:

- App can access the protected capability.

`Denied`:

- User denied access or later disabled it.

`Restricted`:

- Access is restricted by system policy, parental control, MDM, or another macOS constraint.

`Failed`:

- Permission state could not be determined or capture fails despite apparent permission.

## Microphone Permission

Purpose:

- Capture the selected microphone and include it in the mixed virtual input.

Preflight:

- Check microphone authorization status before starting mic capture.
- If `NotDetermined`, show a short app explanation before calling the system request API.
- If `Denied` or `Restricted`, guide the user to System Settings.

User-facing pre-prompt:

```text
Microphone Access

To include your voice in QuickTime recordings, MixedCaptureAudio needs access to your selected microphone.
```

Primary action:

```text
Request Microphone Access
```

Denied-state copy:

```text
Microphone access is off. Open System Settings and allow MixedCaptureAudio to use the microphone, then return here and click Check Again.
```

Actions:

```text
Open System Settings
Check Again
```

## System Audio Access

Purpose:

- Capture computer/system audio through Core Audio process taps.

Preflight:

- There is no microphone-like public status/request API for Core Audio process-tap system audio access.
- Determine access by starting a small test capture path: process tap, private aggregate device, IO proc/block, and observed audio frames.
- A capture path that starts but only delivers silence is not enough to claim readiness.
- If macOS prompts during test capture, use the app’s pre-prompt first.
- If access is denied or capture fails, guide the user to System Settings.

User-facing pre-prompt:

```text
System Audio Access

To include computer sound in QuickTime recordings, MixedCaptureAudio needs permission to capture system audio.
```

Primary action:

```text
Check System Audio Access
```

Denied-state copy:

```text
System audio access is off. Open System Settings, go to Privacy & Security, then Screen & System Audio Recording, and allow MixedCaptureAudio. Return here and click Check Again.
```

Actions:

```text
Open System Settings
Check Again
Run System Audio Test
```

Failure-state copy:

```text
System audio access appears unavailable. Check System Settings, then try again. If this continues, restart the app.
```

`SystemAudioAccessStatus`:

```text
Unknown
NotTested
PromptExpected
Starting
Started
WaitingForSignal
ReceivingAudio
Silent
ProceedUnverified
DeniedOrUnavailable
Failed
```

Rules:

- `PromptExpected` means the app is about to start a test path that may cause macOS to show the system audio recording prompt.
- `Starting` means the app is creating the process tap, private aggregate device, and IO proc/block.
- `Started` means the capture path started but no signal decision has been made.
- `WaitingForSignal` means the capture path is running and the user should play system audio for confirmation.
- `ReceivingAudio` means non-silent frames above the test threshold were observed during the test window.
- `Silent` means the capture path started but only silence was observed during the test window.
- `ProceedUnverified` means a prior successful system-audio check is stored, so setup can display the row as previously verified until fresh audio is observed again.
- `DeniedOrUnavailable` means the test capture failed in a way consistent with missing permission or unavailable system audio access.
- Verified system-audio confidence requires `ReceivingAudio`, not merely `Started`.
- Durable mixer readiness does not require live `ReceivingAudio`; it is based on installed/visible driver, microphone permission, selected microphone availability, and virtual input visibility.
- During active recording, the app may upgrade the system-audio row to `ReceivingAudio` automatically when the virtual input is running and raw system-audio meter peaks prove non-silent computer audio.
- Do not claim system audio `Granted` from stored preferences alone.

## Device And Session States

`SelectedDeviceStatus`:

```text
Unknown
Available
Missing
Failed
```

`MixerStatus`:

```text
Stopped
Starting
Running
Degraded
Failed
```

`QuickTimeDeviceStatus`:

```text
Unknown
Visible
NotVisible
Failed
```

`CaptureSessionState`:

```text
Stopped
CheckingPrerequisites
RequestingPermissions
Ready
Starting
Running
Degraded
Stopping
Failed
```

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

- `Ready` means prerequisites are satisfied but audio capture/mixing is not necessarily active.
- `Running` means the app is actively capturing/mixing and writing to shared memory.
- `Degraded` means capture continues with one or more impaired sources, such as mic missing or system tap failure.
- `Failed` means the session cannot continue without user or system intervention.
- `Ready` is not allowed when `UpdateStatus` is `DriverUpdateRequired` or the installed driver is incompatible.

## First-Launch Onboarding

First launch should open a setup window instead of leaving the user at only a menu-bar icon.

Recommended flow:

1. Welcome.
2. Install/check virtual audio device.
3. Request microphone access.
4. Check system audio access.
5. Choose microphone.
6. Confirm system audio level.
7. Confirm mixer readiness.
8. QuickTime setup instructions.

### Step 1: Welcome

Goal:

- Explain the product in one screen.

Copy:

```text
MixedCaptureAudio creates a virtual input called Mixed Capture Audio. Select it in QuickTime to record computer sound and your microphone together.
```

Primary action:

```text
Start Setup
```

### Step 2: Install/Check Virtual Audio Device

Checks:

- Is `MixedCaptureAudio.driver` installed?
- Is the installed driver compatible with this app version?
- Is the device visible to Core Audio?
- Does installation need reload/restart?

States:

- `Installed`: continue.
- `Missing`: show install action.
- `Incompatible`: show driver update action.
- `InstalledButNeedsReload`: show restart/reload guidance.
- `Failed`: show reinstall/uninstall guidance.

Copy:

```text
Mixed Capture Audio must be installed as a virtual Mac audio input before QuickTime can select it.
```

Primary action:

```text
Install Audio Device
```

Secondary actions:

```text
Check Again
Update Audio Device
Uninstall Audio Device
```

### Step 3: Request Microphone Access

Checks:

- Microphone `PermissionStatus`.

Primary action:

```text
Request Microphone Access
```

Continue when:

- `Granted`.

### Step 4: Check System Audio Access

Checks:

- `SystemAudioAccessStatus`.
- Ability to start the process tap, private aggregate device, and IO proc/block test path.

Primary action:

```text
Check System Audio Access
```

Continue when:

- The capture path reaches `ReceivingAudio`.
- Or the user continues setup with the row still unverified; durable mixer readiness is not blocked by live system-audio confidence.

### Step 5: Choose Microphone

Checks:

- Enumerate input devices.
- Mark default input.
- Detect selected device availability.

UI:

- Microphone picker.
- Mic level meter.
- Refresh devices action.

Continue when:

- Selected mic is `Available`.

### Step 6: Confirm System Audio

Checks:

- Start test system audio tap.
- Show level meter.
- If silence persists, show guidance to play audio or re-check permission.
- During a real QuickTime/Screenshot recording, auto-confirm system audio when the virtual input is running and the raw system-audio source meter proves non-silent computer audio.

UI:

- System audio level meter.
- Capture status.
- Explicit prompt: `Play any sound to confirm system audio.`
- Actions: `Try Again`, `Open System Settings`.

Continue when:

- `SystemAudioAccessStatus` is `ReceivingAudio`.
- Or the user continues with the system-audio row still unverified; the row remains actionable and the `Check System Audio` panel stays near the setup checklist.

### Step 7: Confirm Mixer Readiness

Checks:

- Rust engine can start.
- Shared memory initializes.
- HAL driver is present.
- Health counters are readable.

Continue when:

- `MixerStatus` is `Running` or ready to start.

### Step 8: QuickTime Setup

Copy:

```text
Open QuickTime Player, choose New Screen Recording, open Options, and select Mixed Capture Audio as the microphone.
```

Checklist:

```text
Virtual Audio Device: Installed
Microphone: Granted
System Audio: Receiving Audio / Previously Verified / Not Checked
QuickTime Device: Visible
```

Primary action:

```text
Done
```

Secondary action:

```text
Check Again
```

## Normal App Flow

Menu-bar states:

```text
Stopped
Ready
Running
Degraded
Failed
```

Minimum menu items:

- Open Setup
- Toggle Launch at Startup
- Check System Audio, when unverified
- Quit

When `Running`, show a visible active indicator in the menu-bar menu and setup/diagnostics window. The menu-bar health line reflects recent transport health while ignoring shared-ring movement when no recorder is active; setup diagnostics retain cumulative session counters. The menu status panel should stay anchored just below the MCA status item, fit its current menu content height, and remain inside the visible screen even while Screenshot or QuickTime capture overlays are active.

Do not expose start/stop session controls in the main UX. If the helper is running and durable setup is complete, the app quietly publishes the live mixed input; Quit is the user-visible stop.

## Diagnostics Checklist

Show:

```text
Audio Device: Installed / Missing / Needs Reload / Failed
Audio Device Version: Current / Update Available / Update Required / Failed
Microphone: Granted / Not Determined / Denied / Restricted / Failed
System Audio Test: Unknown / Not Tested / Prompt Expected / Starting / Started / Waiting For Signal / Receiving Audio / Silent / Proceed Unverified / Denied Or Unavailable / Failed
Selected Mic: Available / Missing / Failed
Mixer: Stopped / Starting / Running / Degraded / Failed
QuickTime Device: Visible / Not Visible / Failed
Shared Memory: Healthy / Missing / Stale / Invalid / Failed
```

Diagnostic actions:

- Request missing permissions.
- Open System Settings.
- Check Again.
- Reinstall Audio Device.
- Update Audio Device.
- Open QuickTime Instructions.
- Export Diagnostics, future optional.

Diagnostic export policy is documented in `/tmp/quicktime-mixed-audio-helper-diagnostics-preferences-and-privacy.md`. Exports must be metadata-only and must not include recordings or audio content.

## Denied And Recovery Flows

If microphone is denied:

1. Stop mic capture.
2. Continue system-only mixing only if user explicitly starts in degraded mode.
3. Show `Microphone: Denied`.
4. Offer `Open System Settings` and `Check Again`.

If system audio is denied or unavailable:

1. Stop system audio capture.
2. Continue mic-only mixing only if user explicitly starts in degraded mode.
3. Show `System Audio Test: Denied Or Unavailable`.
4. Offer `Open System Settings` and `Check Again`.

If the selected mic disappears:

1. Continue system audio if possible.
2. Mark session `Degraded`.
3. Show device picker.
4. Do not silently switch microphones without user confirmation unless the user enabled an automatic fallback preference.

If HAL device is missing:

1. Stop or prevent mixing start.
2. Show install action.
3. Do not claim QuickTime readiness.

If HAL driver is incompatible:

1. Stop or prevent mixing start.
2. Show `DriverUpdateRequired`.
3. Offer `Update Audio Device`.
4. Use the signed/notarized package installer flow.
5. Re-check driver version and Core Audio visibility after installation.

## System Settings Guidance

Use direct System Settings links where reliable, but always include text instructions because System Settings URLs can change across macOS versions.

Microphone path:

```text
System Settings -> Privacy & Security -> Microphone
```

System audio path:

```text
System Settings -> Privacy & Security -> Screen & System Audio Recording
```

User actions after changing settings:

```text
Return to MixedCaptureAudio and click Check Again.
Restart the app if macOS requires it.
```

## Testing Permissions

Manual reset commands:

```text
tccutil reset Microphone <bundle-id>
tccutil reset ScreenCapture <bundle-id>
```

The `ScreenCapture` TCC service is the macOS bucket used by Screen & System Audio Recording.

Test scenarios:

- First launch with no permissions granted.
- Grant mic, deny system audio.
- Deny mic, grant system audio.
- Deny both.
- Grant both.
- Revoke mic while app is running.
- Revoke system audio while app is running.
- Missing HAL driver.
- Installed HAL driver but needs reload.
- Selected mic unplugged mid-session.

## References

- Apple media capture authorization: [Requesting authorization for media capture on macOS](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos)
- Apple `NSMicrophoneUsageDescription`: [NSMicrophoneUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription)
- Apple `NSAudioCaptureUsageDescription`: [NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
- Apple user guide: [Control access to screen and system audio recording on Mac](https://support.apple.com/guide/mac-help/mchl2844ecab/mac)
