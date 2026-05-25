# MixedCaptureAudio Plist Requirements

## Summary

The project needs two `Info.plist` files:

```text
App/Resources/Info.plist
HALPlugin/Resources/Info.plist
```

The app plist identifies the user-facing app and declares privacy usage strings. The HAL plist identifies the `.driver` bundle and tells Core Audio how to load the audio server plug-in factory.

Preferred naming:

```text
Product name: MixedCaptureAudio
Base bundle identifier: com.minamiktr.mca
Virtual device display name: Mixed Capture Audio
```

## Bundle Identifiers

Use these identifiers:

```text
App bundle identifier:
com.minamiktr.mca

HAL driver bundle identifier:
com.minamiktr.mca.driver
```

Shared-memory object name:

```text
/mca.mix.v1
```

Keep `.v1` in the shared-memory name so incompatible future layouts can move to `.v2` without confusing old driver/app combinations.

## App Info.plist

Path:

```text
App/Resources/Info.plist
```

Purpose:

- Identifies the app bundle.
- Declares privacy strings for microphone and system audio capture.
- Supplies version metadata.

Required keys:

```xml
<key>CFBundleName</key>
<string>MixedCaptureAudio</string>

<key>CFBundleDisplayName</key>
<string>MixedCaptureAudio</string>

<key>CFBundleIdentifier</key>
<string>com.minamiktr.mca</string>

<key>CFBundleExecutable</key>
<string>MixedCaptureAudio</string>

<key>CFBundlePackageType</key>
<string>APPL</string>

<key>CFBundleShortVersionString</key>
<string>1.0</string>

<key>CFBundleVersion</key>
<string>1</string>

<key>LSMinimumSystemVersion</key>
<string>14.2</string>

<key>NSMicrophoneUsageDescription</key>
<string>MixedCaptureAudio needs microphone access to include your selected mic in the virtual QuickTime input.</string>

<key>NSAudioCaptureUsageDescription</key>
<string>MixedCaptureAudio needs system audio access to include computer audio in the virtual QuickTime input.</string>
```

Notes:

- `CFBundleExecutable` must match the built app executable name.
- Version values should be updated by release tooling.
- If Xcode generates some bundle keys from build settings, keep the effective resolved values aligned with this doc.
- Keep `CFBundleIdentifier` stable across releases so TCC permissions, updater identity, and user preferences remain associated with the same app.

## HAL Driver Info.plist

Path:

```text
HALPlugin/Resources/Info.plist
```

Purpose:

- Identifies the HAL `.driver` bundle.
- Tells Core Audio the executable name.
- Declares the plug-in factory metadata Core Audio uses to instantiate the `AudioServerPlugInDriverInterface`.

Bundle shape:

```text
MixedCaptureAudio.driver/
  Contents/
    Info.plist
    MacOS/
      MixedCaptureAudio
```

Required standard bundle keys:

```xml
<key>CFBundleName</key>
<string>MixedCaptureAudio</string>

<key>CFBundleDisplayName</key>
<string>Mixed Capture Audio</string>

<key>CFBundleIdentifier</key>
<string>com.minamiktr.mca.driver</string>

<key>CFBundleExecutable</key>
<string>MixedCaptureAudio</string>

<key>CFBundlePackageType</key>
<string>BNDL</string>

<key>CFBundleShortVersionString</key>
<string>1.0</string>

<key>CFBundleVersion</key>
<string>1</string>

<key>LSMinimumSystemVersion</key>
<string>14.2</string>
```

Required Core Foundation plug-in keys:

```xml
<key>CFPlugInFactories</key>
<dict>
  <key>REPLACE-WITH-FACTORY-UUID</key>
  <string>MixedCaptureAudio_Create</string>
</dict>

<key>CFPlugInTypes</key>
<dict>
  <key>REPLACE-WITH-AUDIOSERVERPLUGIN-TYPE-UUID</key>
  <array>
    <string>REPLACE-WITH-FACTORY-UUID</string>
  </array>
</dict>
```

Implementation notes:

- `MixedCaptureAudio_Create` is the C factory function exported by the driver executable.
- `REPLACE-WITH-FACTORY-UUID` must be a stable UUID generated once for this driver factory.
- `REPLACE-WITH-AUDIOSERVERPLUGIN-TYPE-UUID` must be the Core Audio audio-server plug-in type UUID expected by Apple’s AudioServerPlugIn loading model.
- During implementation, use Apple’s AudioServerPlugIn sample/docs to fill the exact type UUID and confirm the required plist shape.
- Once confirmed, replace the placeholders in this doc and in `HALPlugin/Resources/Info.plist`.
- Keep the HAL driver `CFBundleIdentifier` stable across releases so the app can reliably identify and verify the installed driver.
- Update `CFBundleShortVersionString` and `CFBundleVersion` through release tooling; the app uses these values for compatibility checks.

## Update Metadata

The plist version fields are part of the app/driver update contract.

Recommended rules:

- App-only updates may change only the app plist version fields.
- Driver updates must change the HAL plist version fields when driver code, HAL metadata, or shared-memory reader behavior changes.
- Incompatible shared-memory layout, fixed output-format, or target shared-fill constant changes must also update the shared-memory ABI contract and may require moving from `.v1` to `.v2`.
- The app should reject or warn on drivers whose bundle identifier, version, shared-memory ABI, output format, or target shared-fill constant is outside the supported range.

Full update policy is documented in:

```text
/tmp/quicktime-mixed-audio-helper-update-and-installation-strategy.md
```

## Mach Services

Preferred V1 path does not declare `AudioServerPlugIn_MachServices`.

Reason:

- The preferred HAL plug-in data plane reads shared memory only.
- The HAL plug-in must not use Mach/XPC for audio IO.
- Any plug-in-to-app channel must be non-real-time and documented separately.

However, this is conditional on the shared-memory-across-`coreaudiod` sandbox spike passing. Apple QA1811 documents that AudioServerPlugIns run in a sandboxed host and that plug-ins must list Mach services they need to access in `AudioServerPlugIn_MachServices`.

If POSIX shared memory is blocked and a fallback is required, document and add:

```xml
<key>AudioServerPlugIn_MachServices</key>
<array>
  <string>REPLACE-WITH-NARROW-MACH-SERVICE-NAME</string>
</array>
```

Fallback requirements:

- service name
- service owner: app or helper
- purpose
- whether it is used outside IO callbacks only
- required plist key
- security implications
- proof that audio IO remains non-blocking, allocation-free, and does not call XPC/Mach

## HAL Display Metadata

The plist identifies the bundle. The HAL property implementation identifies the Core Audio device shown to users.

Use:

```text
Device name: Mixed Capture Audio
Manufacturer: Minami
Device UID: com.minamiktr.mca.device.MixedCaptureAudio
Model UID: com.minamiktr.mca.model.MixedCaptureAudio
```

Do not expose `MixedCaptureAudio` as the device display name in QuickTime; use the spaced name `Mixed Capture Audio`.

## Validation

App plist validation:

- App bundle ID resolves to `com.minamiktr.mca`.
- App executable is `MixedCaptureAudio`.
- `NSMicrophoneUsageDescription` exists.
- `NSAudioCaptureUsageDescription` exists.
- Minimum system version is macOS 14.2.

HAL plist validation:

- Driver bundle ID resolves to `com.minamiktr.mca.driver`.
- Driver executable is `MixedCaptureAudio`.
- Package type is `BNDL`.
- `CFPlugInFactories` exists.
- `CFPlugInTypes` exists.
- Factory function name is `MixedCaptureAudio_Create`.
- Factory UUID is stable and not regenerated per build.
- AudioServerPlugIn type UUID is confirmed against Apple docs/sample.

## References

- Apple bundle keys: [Information Property List](https://developer.apple.com/documentation/bundleresources/information-property-list)
- Apple `NSMicrophoneUsageDescription`: [NSMicrophoneUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription)
- Apple `NSAudioCaptureUsageDescription`: [NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
- Apple Audio Server Driver Plug-in guide: [Creating an audio server driver plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- Apple QA1811: [Audio Server PlugIn - The AudioServerPlugIn_MachServices plist Key](https://developer.apple.com/library/archive/qa/qa1811/_index.html)
