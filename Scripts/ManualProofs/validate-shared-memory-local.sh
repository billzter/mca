#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if pgrep -qx SharedMemoryProducer >/dev/null 2>&1; then
  printf 'SharedMemoryProducer is already running. Stop it before running this local validator; this script creates and removes /mca.mix.v1 for isolated tests.\n' >&2
  exit 1
fi

sh Scripts/Support/build-shared-memory-producer.sh >/tmp/mca-shm-local-producer-build.log
sh Scripts/Support/build-shared-memory-probe-tests.sh >/tmp/mca-shm-local-probe-build.log
Build/Debug/Tools/MixedAudioSharedMemoryProbeTests >/tmp/mca-shm-local-probe-test.log
Build/Debug/Tools/SharedMemoryProducer --once >/tmp/mca-shm-local-producer-once.log
sh Scripts/build-hal-driver.sh >/tmp/mca-shm-local-hal-build.log

printf 'shared-memory local validation passed\n'
