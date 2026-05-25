# MixedCaptureAudio Diagnostics, Preferences, And Privacy

## Summary

`MixedCaptureAudio` is an audio-path enabler, not a recorder.

It creates a live virtual audio input that another app, such as QuickTime, can record when the user chooses. `MixedCaptureAudio` should not record, store, upload, transcribe, or retain audio content.

Core product promise:

```text
MixedCaptureAudio does not store recordings.
MixedCaptureAudio does not write mic, system, or mixed audio to disk.
MixedCaptureAudio only maintains live audio buffers required to feed the virtual input.
QuickTime or another recording app owns any recording the user creates.
```

## Privacy Rules

V1 must follow these rules:

- Do not store audio samples.
- Do not write mic audio, system audio, per-app audio, or mixed audio to disk.
- Do not upload audio.
- Do not transcribe audio.
- Do not retain audio buffers after the live mixer/transport path no longer needs them.
- Do not log audio sample values.
- Do not log window titles, document names, browser tab titles, or user content.
- Do not add remote telemetry in v1.
- Keep diagnostics local unless the user explicitly exports them.

The app may maintain short-lived in-memory buffers required for live capture, mixing, and HAL delivery. Those buffers are implementation state, not recordings.

## Diagnostics Scope

Diagnostics should help users and developers answer:

- Is the HAL driver installed?
- Is the HAL driver compatible?
- Is the Core Audio device visible?
- Is microphone permission granted?
- Does the system audio access test pass?
- Is the selected microphone available?
- Is the mixer running, stopped, degraded, or failed?
- Is shared memory healthy, missing, stale, invalid, or underrunning?
- Are app/driver versions compatible?

Diagnostics should not answer:

- What did the user say?
- What system audio was playing?
- Which document, browser tab, or private content was open?
- What QuickTime recorded?

## Allowed Diagnostic Data

Allowed local diagnostic fields:

```text
app version
driver version
shared-memory ABI version
target shared-fill ABI constant
macOS version
machine architecture
app bundle identifier
driver bundle identifier
driver install path
driver install state
driver compatibility state
Core Audio device visibility state
microphone permission state
system audio access test state
selected microphone device UID
selected microphone display name
selected microphone availability state
session state
mixer state
update state
shared-memory state
ring-buffer capacity
ring-buffer fill level
ring-buffer fill error relative to target shared-fill constant
underrun count
overrun count
dropped-frame count
clipped-frame count
producer heartbeat age
generation counter
recent non-audio errors
recent state transitions
```

Allowed counters are metadata about transport health. They are not audio content.

## Disallowed Diagnostic Data

Never include:

```text
audio sample buffers
raw mic audio
raw system audio
mixed audio
QuickTime recordings
recorded files
transcripts
window titles
document names
browser tab titles
captured screen contents
full process/window activity history
secret tokens
permission tokens
arbitrary file paths unrelated to app/driver installation
```

If future per-app capture is added, app include/exclude preferences may reveal user behavior. Treat them as local user preferences and include them in diagnostics only if the user explicitly chooses to export detailed preferences.

## Logging Policy

Use logs for state transitions and errors, not audio data.

Allowed log events:

- app launched
- app exited
- setup opened
- permission state changed
- driver install state changed
- driver compatibility check result
- Core Audio device visibility check result
- selected microphone changed
- session started
- session stopped
- session entered `Degraded`
- session failed with non-audio error code
- shared-memory validation failed
- heartbeat stale
- underrun/overrun counters crossed a threshold
- update check result
- installer flow started or completed

Disallowed log events:

- per-buffer audio callback logs
- per-frame logs
- sample values
- raw audio dumps
- captured media data
- system audio content descriptions
- microphone content descriptions

Real-time rule:

- Do not log from audio callbacks or HAL IO callbacks.
- Hot paths update counters only.
- Non-real-time diagnostics code may snapshot counters and write logs.

## Log Storage

V1 should keep logs local.

Recommended locations:

```text
App logs:
~/Library/Logs/MixedCaptureAudio/

App support diagnostics:
~/Library/Application Support/MixedCaptureAudio/Diagnostics/
```

Recommended retention:

- Keep logs bounded by size and age.
- Prefer a small rolling log.
- Do not keep indefinite diagnostic history.
- Do not create logs until the app runs.

Suggested initial retention:

```text
maximum age: 14 days
maximum total log size: 50 MB
```

These values can be adjusted after prototype support needs are clearer.

## Diagnostic Export

Diagnostic export should be an explicit user action.

Export should create a metadata-only archive or text report containing:

```text
app version
driver version
macOS version
architecture
permission states
driver install/compatibility state
Core Audio device visibility state
selected microphone metadata
mixer/session state
shared-memory health counters
recent non-audio errors
recent state transitions
update state
```

Export should not include:

```text
audio data
recordings
screen captures
window titles
document names
browser tabs
full process history
```

Before export, show a short explanation:

```text
This export contains MixedCaptureAudio setup state, versions, permission states, and audio-transport health counters. It does not include recordings or audio content.
```

For v1, diagnostic export can remain optional. The privacy/logging rules should still be implemented from the beginning.

## Preferences Storage

Use normal app-local preference storage for user settings.

Recommended default:

```text
UserDefaults suite for com.minamiktr.mca
```

For values that become too large or structured for `UserDefaults`, use:

```text
~/Library/Application Support/MixedCaptureAudio/
```

V1 should not require a database.

## Allowed Preferences

Allowed preferences:

```text
onboarding completed
selected microphone device UID
selected microphone display name
mic gain
system audio gain
mic muted
system audio muted
monitor output enabled
monitor output device UID, if implemented
start at login, if implemented
start mixing automatically, if implemented
last selected capture mode
QuickTime setup tips dismissed
diagnostics window preferences
update preference
last seen compatible driver version
last successful setup check timestamp
```

For v1, `last selected capture mode` should be global system audio plus one selected mic. Per-app capture mode can be reserved internally but should not expose per-app include/exclude UI until that feature is implemented.

## Disallowed Preferences

Do not store:

```text
audio samples
audio recordings
audio transcripts
raw capture buffers
QuickTime output files
system audio content metadata
permission tokens
secret tokens
arbitrary process/window history
```

Do not store selected microphone state as proof that the device still exists. Always re-check device availability at launch and before starting a session.

## Settings Model

Recommended settings model:

```text
AppSettings
  onboardingCompleted: Bool
  selectedMicrophoneUID: String?
  selectedMicrophoneDisplayName: String?
  micGain: Float
  systemGain: Float
  micMuted: Bool
  systemMuted: Bool
  monitoringEnabled: Bool
  monitorOutputDeviceUID: String?
  startAtLoginEnabled: Bool
  autoStartMixingEnabled: Bool
  updatePreference: UpdatePreference
  quickTimeTipsDismissed: Bool
  lastCompatibleDriverVersion: String?
```

`UpdatePreference`:

```text
Manual
AutomaticAppOnly
```

Driver updates still use the signed/notarized package installer flow and should not be silently installed by a background helper in v1.

## Defaults

Recommended defaults:

```text
onboardingCompleted: false
micGain: 1.0
systemGain: 1.0
micMuted: false
systemMuted: false
monitoringEnabled: false
startAtLoginEnabled: false
autoStartMixingEnabled: false
updatePreference: Manual
quickTimeTipsDismissed: false
```

Do not auto-start capture on first launch.

If auto-start mixing is added later, keep it opt-in and keep a visible running state.

## Preference Migration

Preferences should include a schema version if structured settings move beyond simple `UserDefaults` keys.

Migration rules:

- Missing preference values use safe defaults.
- Unknown preference keys are ignored.
- Invalid selected microphone UID becomes `SelectedDeviceStatus.Missing`.
- Invalid gain values clamp to safe ranges.
- Driver compatibility is never trusted from preferences alone.
- Permission state is never trusted from preferences.

## Future Per-App Audio Preferences

Per-app audio is future scope.

If implemented later, potential preferences include:

```text
capture mode
included application bundle identifiers
excluded application bundle identifiers
last selected app/process display names
```

Privacy rule:

- Treat app include/exclude lists as sensitive local preferences.
- Do not include them in basic diagnostics.
- Include them in diagnostic export only if the user explicitly chooses a detailed export.

## Tests

Add tests for:

- default settings load correctly
- settings persist across app restart
- invalid gain values are clamped
- missing microphone UID maps to `SelectedDeviceStatus.Missing`
- permission states are re-queried and not trusted from preferences
- driver compatibility is re-queried and not trusted from preferences
- diagnostic export excludes audio data
- diagnostic export excludes window titles, document names, and browser tabs
- diagnostic export includes allowed state/counter metadata
- logs are not written from audio callbacks
- logs are bounded by size/age

Manual checks:

- Start app, complete onboarding, quit, relaunch, selected mic preference remains.
- Revoke microphone permission, relaunch, app reports actual permission state rather than stored state.
- Uninstall driver, relaunch, app reports missing driver rather than stored compatible state.
- Export diagnostics and inspect that no audio or recording content is present.

## References

- Apple `UserDefaults`: [UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults)
- Apple file-system domains: [File System Programming Guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)
