#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if pgrep -qx SharedMemoryProducer >/dev/null 2>&1; then
  printf 'SharedMemoryProducer is running. Stop it before validating missing-producer silence.\n' >&2
  exit 1
fi

sh Scripts/Support/build-audio-device-list.sh >/tmp/mca-coreaudiod-missing-device-list-build.log
sh Scripts/Support/build-capture-mixed-capture-audio.sh >/tmp/mca-coreaudiod-missing-capture-build.log

if ! Build/Debug/Tools/ListAudioDevices | grep 'Mixed Capture Audio' >/tmp/mca-coreaudiod-missing-device-list-check.log; then
  printf 'Mixed Capture Audio is not visible. Install the HAL driver and restart coreaudiod first.\n' >&2
  exit 1
fi

Build/Debug/Tools/CaptureMixedCaptureAudio --frames 4800 --timeout-ms 5000 --expect silence

printf 'Core Audio missing-producer silence validation passed\n'
