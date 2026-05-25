#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if pgrep -qx SharedMemoryProducer >/dev/null 2>&1; then
  printf 'SharedMemoryProducer is already running. Stop it before running this local validator; this script creates and removes /mca.mix.v1 for isolated tests.\n' >&2
  exit 1
fi

sh Scripts/Support/build-shared-memory-producer.sh >/tmp/mca-hal-io-producer-build.log
sh Scripts/Support/build-shared-memory-reader-tests.sh >/tmp/mca-hal-io-reader-build.log
sh Scripts/build-hal-driver.sh >/tmp/mca-hal-io-driver-build.log
sh Scripts/Support/build-hal-smoke-tests.sh >/tmp/mca-hal-io-smoke-build.log
sh Scripts/Support/build-hal-shared-memory-io-tests.sh >/tmp/mca-hal-io-build.log
sh Scripts/Support/build-capture-mixed-capture-audio.sh >/tmp/mca-coreaudiod-capture-build.log

Build/Debug/Tools/MixedAudioSharedMemoryReaderTests >/tmp/mca-hal-io-reader-test.log
Build/Debug/Tools/SharedMemoryProducer --once >/tmp/mca-hal-io-producer-once.log
Build/Debug/Tools/MixedCaptureAudioDriverSmokeTests >/tmp/mca-hal-io-smoke-test.log
Build/Debug/Tools/MixedCaptureAudioSharedMemoryIOTests >/tmp/mca-hal-io-test.log

printf 'HAL shared-memory IO validation passed\n'
