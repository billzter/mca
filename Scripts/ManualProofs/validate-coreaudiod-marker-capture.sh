#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

sh Scripts/Support/build-audio-device-list.sh >/tmp/mca-coreaudiod-marker-device-list-build.log
sh Scripts/Support/build-capture-mixed-capture-audio.sh >/tmp/mca-coreaudiod-capture-build.log

if ! Build/Debug/Tools/ListAudioDevices | grep 'Mixed Capture Audio' >/tmp/mca-coreaudiod-marker-device-list-check.log; then
  printf 'Mixed Capture Audio is not visible. Install the HAL driver and restart coreaudiod first.\n' >&2
  exit 1
fi

Build/Debug/Tools/CaptureMixedCaptureAudio --frames 4800 --timeout-ms 5000

printf 'Core Audio marker capture validation passed\n'
