# MixedCaptureAudio Remaining Confirmations

## Summary

The architecture is documented enough to begin implementation, but a few Apple-specific details need prototype evidence before they become final release rules.

These are not open architecture decisions. They are confirmation tasks:

- inspect real system behavior
- record the result
- update the implementation docs
- encode the result in scripts, tests, or release tooling

## Shared Memory Across `coreaudiod` Sandbox

This is a go/no-go gate for the preferred data plane.

What needs to be determined:

- Can an AudioServerPlugIn loaded by sandboxed `coreaudiod` call `shm_open` on the app-created object?
- Can it `mmap` the object read-only or read/write as required?
- Do sandbox deny messages appear?
- Does behavior differ between ad hoc/local signing and Developer ID signing?
- Does behavior differ on a clean Mac versus the development machine?

Evidence matrix:

```text
App creates /mca.mix.v1
HAL plug-in opens the object from coreaudiod
HAL plug-in maps the object
HAL plug-in reads known ramp/sine frames
HAL plug-in returns silence when object is missing
Console/log stream checked for sandbox denies
Repeat after reboot/reload
Repeat on clean target Mac
```

Acceptance:

- Preferred POSIX shared-memory path is allowed only if this passes.
- If it fails, prototype a non-real-time Mach/XPC setup fallback before continuing deeper implementation.
- The IO path must remain non-blocking, allocation-free, and free of XPC/Mach calls.

## Non-Real-Time Mach/XPC Setup Fallback

This fallback is only for the case where POSIX shared memory cannot be opened/mapped directly by the HAL plug-in.

What needs to be determined:

- Can `AudioServerPlugIn_MachServices` allow the HAL plug-in to contact a narrow app/helper service?
- Can the service establish the required mapping, descriptor, or configuration outside IO callbacks?
- Can the IO path still read from pre-established state without blocking?
- Does the fallback require a helper distinct from the app?
- Does the fallback change signing, launch, installation, or uninstall behavior?

Acceptance:

- Any Mach/XPC communication happens before or outside IO.
- The HAL IO path still only performs atomic reads, pointer-safe copies, and silence fallback.
- If this cannot be proven, the virtual-device architecture must be reassessed.

## Source Rate, ASRC, And Drift

This is a go/no-go gate for the audio engine quality target.

What needs to be determined:

- What formats and cadences do Core Audio taps produce for 44.1 kHz and 48 kHz output devices?
- What formats and cadences do common microphones produce?
- How much drift accumulates between system/tap and microphone sources over 10 minutes?
- How much shared-ring fill drift accumulates between app/Rust producer and HAL/coreaudiod consumer over 30-60 minutes?
- Which source timing metadata is available and reliable?
- Is simple capture-side normalization enough, or does Rust need dedicated SRC/ASRC immediately?
- Does the fixed V1 target shared-ring fill ABI constant avoid underruns without excessive latency?
- Does HAL report the fixed target-fill latency correctly when the app is stopped and shared memory does not exist?
- What maximum residual A/V sync error is acceptable from shared-ring fill deviation?
- What active-session mixer scheduling policy is required to keep wakeup jitter inside the fixed target-fill budget?
- What final-stage rate-trim bounds are transparent enough for audio quality?

Evidence matrix:

```text
44.1 kHz output device -> system tap format/cadence -> Rust input metadata
48 kHz output device -> system tap format/cadence -> Rust input metadata
Selected mic at 44.1/48 kHz where possible -> mic format/cadence
10-minute system+mic run -> drift/underrun/overrun counters
10-minute synthetic cadence simulation -> bounded buffer growth
30-60 minute producer-to-HAL run -> shared-ring min/max/mean fill
30-60 minute producer-to-HAL run -> shared-ring fill error min/max/mean/p95/p99
30-60 minute producer-to-HAL run -> drift-induced underrun/overrun counters
app stopped -> HAL reported latency includes fixed target fill
fixed target fill -> HAL reported latency -> measured QuickTime A/V sync
loaded system -> mixer wakeup jitter -> shared-ring underrun counters
```

Acceptance:

- Rust owns long-term drift monitoring and rate-matching policy.
- Rust uses shared-ring fill level as the final producer-to-HAL clock-control signal.
- HAL reports fixed target shared-ring fill as part of device/input latency whether or not the app is running.
- Residual fill error stays within the chosen A/V sync budget, or the controller/scheduling/ABI constant is adjusted before release.
- Active-session mixer scheduling keeps wakeup jitter below the fixed target-fill budget with margin, or the ABI constant is raised and reported latency changes with it.
- The app can either handle 44.1 kHz sources or report an explicit unsupported condition during prototype.
- Final Phase 2 acceptance must use measured drift/underrun thresholds, not only “sounds okay.”

## Process Tap And Aggregate-Device Capture

What needs to be determined:

- Exact Core Audio process-tap creation flow.
- Exact private aggregate-device description required to receive frames from the tap.
- IO proc/block setup and teardown sequence.
- Stream format discovery from the tap.
- Failure behavior when permission is missing, prompt is pending, or the tap cannot start.

Acceptance:

- Phase 0 proof-of-signal includes process tap, private aggregate device, IO proc/block, and teardown.
- The app treats system-audio access as test-capture driven, not query/request driven.

## HAL Timing And Latency

What needs to be determined:

- Correct `GetZeroTimeStamp` host-time anchoring pattern.
- Reported device latency.
- Whether reported latency includes the fixed target shared-ring fill while the app is stopped and while it is running.
- Whether QuickTime A/V sync remains acceptable with the virtual input selected.
- Whether timestamp behavior differs when the app producer is stopped and HAL outputs silence.

Acceptance:

- HAL timeline advances steadily even when producer data is missing.
- Timestamp behavior is independent of producer heartbeat.
- QuickTime manual acceptance includes A/V sync validation.

## Driver Install Permissions

The HAL driver installs to:

```text
/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver
```

What needs to be determined:

- owner for the installed bundle
- group for the installed bundle
- directory permissions
- executable permissions
- `Info.plist` and resource permissions
- whether quarantined attributes or extended attributes affect Core Audio loading
- whether Core Audio refuses to load the driver when ownership or permissions are wrong

Expected baseline:

```text
owner: root
group: wheel
directories: 755
executables: 755
plists/resources: 644
```

This baseline should be verified against:

- Apple-installed or third-party HAL plug-ins on a real Mac
- a prototype `MixedCaptureAudio.driver`
- the final `.pkg` installer payload

Evidence to collect:

```text
ls -la /Library/Audio/Plug-Ins/HAL
ls -la /Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver
find /Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver -ls
xattr -lr /Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver
codesign --verify --deep --strict /Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver
```

Release rule:

- The installer package must set the confirmed owner/group/modes.
- Development install scripts should mirror package behavior closely.
- The app should diagnose missing, incompatible, or suspicious driver installs, but it should not silently fix privileged filesystem state in v1.

## Core Audio Reload Behavior

Installing or replacing the HAL driver does not guarantee that every Core Audio client immediately sees the new state. Core Audio may already have loaded the plug-in, and apps like QuickTime may cache device lists while open.

What needs to be determined:

- Does the virtual input appear immediately after first install?
- Does `coreaudiod` need to restart?
- Does logout/restart produce different behavior than restarting `coreaudiod`?
- Does QuickTime need to be closed and reopened?
- What happens when the driver is replaced while a client is using it?
- What happens when the app is mixing while a driver update starts?
- What happens after uninstall?

Evidence matrix:

```text
Fresh install -> enumerate devices -> QuickTime device list
Install while QuickTime is open -> QuickTime device list refresh behavior
Replace driver while no clients are using it -> version/device behavior
Replace driver while QuickTime is open -> version/device behavior
Replace driver while capture is running -> app state and HAL output
Uninstall driver -> enumerate devices -> QuickTime device list
Restart app only -> re-check driver/device visibility
Restart QuickTime only -> re-check device visibility
Restart coreaudiod in developer test -> re-check device visibility
Logout/restart -> re-check device visibility
```

Acceptance:

- User-facing instructions must be reliable, even if slightly conservative.
- V1 should prefer close/reopen QuickTime or restart/logout guidance over force-restarting Core Audio.
- Developer scripts may support explicit Core Audio reload, but only with clear confirmation.

Documentation updates after prototype:

- update HAL reload guidance
- update onboarding `InstalledButNeedsReload` behavior
- update installer post-install copy
- update test plan commands

## Sparkle And Package Update Behavior

Sparkle is a macOS updater framework. It can check an update feed, show release notes, download signed updates, verify them, and replace the app.

V1 update strategy:

- app-only updates can use Sparkle or an equivalent signed updater
- driver updates should use a signed/notarized `.pkg` installer
- no privileged background update helper in v1

What needs to be determined:

- whether Sparkle package updates fit the HAL driver installer flow cleanly
- whether Sparkle should be added in v1 or after the first installer-based release
- whether app-only updates should be automatic by default or manual by default
- how update feed metadata represents app version, driver version, shared-memory ABI, and target shared-fill constant
- how the app blocks `Ready` when an app-only update requires a newer driver

Recommended v1 release posture:

- First public builds may ship as full signed/notarized installer packages.
- Add Sparkle app-only updates after the installer, driver verification, and compatibility checks are proven.
- Use package installer flow for HAL driver changes even after app-only updates are available.

Terminology:

```text
App-only update:
updates /Applications/MixedCaptureAudio.app only

Driver update:
installs/replaces /Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver

Full installer package:
a signed/notarized macOS .pkg that can install the app, the HAL driver, or both
```

## System Audio Permission Reset And Testing

Testing permission onboarding requires returning the app to first-run-like TCC states.

Microphone reset is expected to use:

```text
tccutil reset Microphone com.minamiktr.mca
```

System audio capture reset behavior still needs validation because macOS TCC service names and UI behavior can vary by capability and OS version.

What needs to be determined:

- exact reset command for system audio capture permission, if available
- whether reset works per bundle identifier
- whether app relaunch is required after reset
- whether System Settings changes are visible immediately to the app
- what the test-capture flow reports for Unknown, NotTested, PromptExpected, Starting, Started, WaitingForSignal, ReceivingAudio, Silent, ProceedUnverified, DeniedOrUnavailable, and Failed states
- whether Screen & System Audio Recording UI state maps cleanly to app diagnostics

Evidence to collect:

```text
fresh app bundle id -> run system audio test capture -> observe prompt if macOS shows one
deny -> app state
grant through System Settings -> app state
reset through tccutil if possible -> app state
relaunch after reset -> app state
repeat on each target macOS version
```

Release rule:

- Onboarding must not claim system audio is available until the capture path actually works.
- Onboarding may let the user proceed unverified from a silent machine, but diagnostics must keep system audio marked unverified until audio is observed.
- Diagnostics should include practical capture-test state.
- Test docs should record exact reset commands only after prototype validation.

## Numeric Test Thresholds

Audio quality thresholds need prototype data.

What needs to be measured:

- end-to-end latency
- target shared-ring fill latency
- drift over 10 minutes
- source-rate conversion error
- underrun count under normal load
- overrun behavior under stress
- clipping count at default gains
- CPU usage while mixing
- memory usage while idle and running
- recovery time after app restart while HAL client is active
- recovery time after generation change

Initial qualitative rule:

- no crash
- no hang
- no continuous underrun pattern under normal load
- no obvious drift over 10 minutes
- no audible clipping at default gains for normal inputs
- missing producer state becomes silence, never stale/noisy data

Prototype evidence should turn those qualitative rules into numeric thresholds.

Examples of final thresholds to define after measurement:

```text
maximum steady-state underruns per minute
maximum drift over 10 minutes
maximum source-rate conversion error
maximum acceptable target shared-ring fill
maximum acceptable residual sync error from shared-ring fill deviation
maximum recovery time after app restart
maximum CPU usage on target hardware
maximum allowed clipped frames at default gain
```

## Entitlements, Signing, And Apple Developer Account

Local development can begin without a paid Apple Developer Program account, but distribution almost certainly requires one.

Local prototype:

- build with Xcode local/ad hoc signing
- run Rust/C/Swift unit tests
- install HAL driver manually for development
- expect Gatekeeper, quarantine, or trust friction outside the developer machine

Clean distribution:

- Developer ID Application signing for the app
- Developer ID signing for the HAL driver bundle as applicable
- Developer ID Installer signing for `.pkg` installers
- notarization for distributed artifacts
- stapling where applicable
- hardened runtime where applicable

Practical rule:

```text
Prototype locally: Apple Developer Program not strictly required.
Share rough builds privately: possible, but expect trust/install friction.
Distribute cleanly to users: Apple Developer Program required.
Ship signed/notarized app and pkg: Apple Developer Program required.
```

Entitlements still need confirmation after the app target and capture APIs are wired.

What needs to be determined:

- exact app entitlements required for Core Audio process taps
- exact app entitlements required for microphone capture
- whether hardened runtime needs specific audio/camera/microphone exceptions
- whether the HAL driver needs any special signing options beyond normal Developer ID signing
- whether the package installer needs any postinstall scripts and how those scripts are signed/notarized

Release rule:

- Do not finalize signing docs until the first end-to-end signed/notarized prototype installs and runs on a clean Mac.

## Confirmation Order

Recommended order:

1. HAL plist/factory metadata confirmation.
2. Shared-memory-across-`coreaudiod` sandbox spike.
3. Non-real-time Mach/XPC setup fallback spike, only if the shared-memory gate fails.
4. Driver install permissions confirmation.
5. Core Audio reload behavior confirmation.
6. Process tap plus aggregate-device capture confirmation.
7. Source rate, ASRC, and drift confirmation.
8. HAL timing and latency confirmation.
9. System audio permission reset/testing confirmation.
10. Signing/notarization prototype.
11. Sparkle/package update prototype.
12. Numeric audio thresholds after real capture/mix data.

## References

- Sparkle documentation: [Documentation](https://sparkle-project.github.io/documentation/)
- Sparkle package updates: [Package Updates](https://sparkle-project.github.io/documentation/package-updates/)
- Apple Developer ID: [Developer ID](https://developer.apple.com/support/developer-id/)
- Apple notarization: [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- Apple packaging: [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
