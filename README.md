# MixedCaptureAudio

MixedCaptureAudio is a native macOS menu-bar helper that publishes a virtual Core Audio input named `Mixed Capture Audio`. Select it in QuickTime Player, Screenshot, or another recorder to capture a live mix of system audio and one microphone.

![MixedCaptureAudio setup window](docs/assets/readme/setup-ready.png)

## What It Does

- Creates a virtual microphone-style input device for macOS recording apps.
- Mixes program audio and the active microphone into one stereo stream.
- Supports all-app program audio or selected-app program audio.
- Lets you choose an active microphone and keep a fallback priority list.
- Keeps capture running from the menu-bar helper instead of exposing session start/stop controls.
- Shows local setup, permission, device, mixer, and shared-ring health diagnostics.

![MixedCaptureAudio menu-bar status](docs/assets/readme/menu-bar-status.png)

## How It Works

MixedCaptureAudio is split into an app, a mixer, and a HAL driver. The app owns permissions, device selection, Core Audio process taps, microphone capture, and UI. The Rust mixer owns deterministic audio mixing and shared-memory writing. The HAL driver owns the virtual input device that recording apps read from.

```mermaid
flowchart LR
    User["Setup / Menu Bar"] --> App["Swift + AppKit app"]
    App --> Tap["Core Audio process tap"]
    App --> Mic["Microphone capture"]
    Tap --> Mixer["Rust mixer"]
    Mic --> Mixer
    Mixer --> SHM["POSIX shared ring<br/>/mca.mix.v1"]
    HAL["Core Audio HAL driver"] --> SHM
    HAL --> Recorder["QuickTime / Screenshot"]
```

The HAL-facing stream is fixed at 48 kHz, stereo, interleaved `Float32`. The virtual device reads from `/mca.mix.v1`; bad, stale, or missing data becomes silence rather than blocking Core Audio.

For the deeper architecture map, see [docs/mixed-capture-audio-project-reference.md](docs/mixed-capture-audio-project-reference.md).

## Requirements

- macOS 14.2 or newer.
- Microphone permission for the app.
- System Audio permission for program-audio capture.
- A recording app that can select a Core Audio input device, such as QuickTime Player or Screenshot.

## Install And Use

1. Install the latest `MixedCaptureAudio-*.pkg` from Releases.
2. Open `MixedCaptureAudio`.
3. Grant microphone access when prompted.
4. Use `Check System Audio` while audible system audio is playing.
5. Choose the active microphone and fallback order in setup.
6. Choose `All Apps` or `Selected Apps` for program audio.
7. In QuickTime Player or Screenshot, select `Mixed Capture Audio` as the audio input.

The helper is an `LSUIElement` menu-bar app. Closing the setup window leaves the helper running; use the menu-bar `Quit` action to stop it.

## Development

Run the full local verification surface:

```sh
Scripts/mca-build verify
```

Build the app, HAL driver, and unsigned installer package:

```sh
Scripts/build-app.sh
Scripts/build-hal-driver.sh
Scripts/mca-build package
```

Build release artifacts when signing and notarization credentials are configured:

```sh
Scripts/mca-build release --version 0.0.4 --build 123
Scripts/mca-build release-notarized --version 0.0.4 --build 123
```

Useful focused checks:

```sh
Scripts/validate-rust-engine.sh
Scripts/validate-app.sh
Scripts/validate-build-system.sh
Scripts/validate-packaging.sh
```

## Repository Map

| Path | Purpose |
| --- | --- |
| `App/Sources/App/` | Swift app model, setup UI, menu-bar UI, permissions, preferences, and lifecycle control |
| `App/Sources/Audio/LiveMixerSession.m` | Objective-C capture bridge between Swift, Core Audio, microphone capture, and Rust |
| `Rust/mixed-audio-engine/` | Mixer, source queues, shared-memory writer, health counters, and Rust tests |
| `HALPlugin/` | C AudioServerPlugIn virtual input device and shared-memory reader |
| `Scripts/` | Build, validation, package, signing, notarization, install, and uninstall helpers |
| `docs/` | Architecture, release, permissions, diagnostics, and verification notes |

## Privacy

MixedCaptureAudio does not create recordings, upload audio, or use analytics. Audio is captured locally, mixed locally, and exposed locally as a virtual Core Audio input. Recording ownership stays with the app that selected `Mixed Capture Audio`.

Local diagnostics describe device state, permission state, capture health, and shared-ring counters. They are intended for setup and troubleshooting, not telemetry.

## Troubleshooting

If `Mixed Capture Audio` is not visible in a recorder, quit and reopen the recorder first. If it is still missing, reload Core Audio or restart the Mac after installation.

If system audio is not detected, make sure something audible and unmuted is playing, then run `Check System Audio` again.

To uninstall while preserving macOS privacy decisions:

```sh
Scripts/uninstall-mca.sh
```

To reset local app preferences:

```sh
defaults delete com.minamiktr.mca 2>/dev/null || true
```

To forget the installer package receipt:

```sh
sudo pkgutil --forget com.minamiktr.mca.pkg 2>/dev/null || true
```
