#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if pgrep -qx SharedMemoryProducer >/dev/null 2>&1; then
  printf 'SharedMemoryProducer is running. Stop it before validating the Rust producer.\n' >&2
  exit 1
fi

if pgrep -qx RustSharedMemoryProducer >/dev/null 2>&1; then
  printf 'RustSharedMemoryProducer is already running. Stop it before this validation starts its own producer.\n' >&2
  exit 1
fi

sh Scripts/Support/build-rust-shared-memory-producer.sh >/tmp/mca-coreaudiod-rust-producer-build.log
sh Scripts/Support/build-audio-device-list.sh >/tmp/mca-coreaudiod-rust-device-list-build.log
sh Scripts/Support/build-capture-mixed-capture-audio.sh >/tmp/mca-coreaudiod-rust-capture-build.log

Build/Debug/Tools/RustSharedMemoryProducer >/tmp/mca-coreaudiod-rust-producer.log 2>&1 &
producer_pid=$!
trap 'kill "$producer_pid" >/dev/null 2>&1 || true; wait "$producer_pid" >/dev/null 2>&1 || true' EXIT

sleep 1

if ! Build/Debug/Tools/ListAudioDevices | grep 'Mixed Capture Audio' >/tmp/mca-coreaudiod-rust-device-list-check.log; then
  printf 'Mixed Capture Audio is not visible. Install the HAL driver and restart coreaudiod first.\n' >&2
  exit 1
fi

Build/Debug/Tools/CaptureMixedCaptureAudio --frames 4800 --timeout-ms 5000 --expect marker

printf 'Core Audio Rust producer validation passed\n'
