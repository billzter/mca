#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if pgrep -qx SharedMemoryProducer >/dev/null 2>&1; then
  printf 'SharedMemoryProducer is already running. Stop it before this stale-heartbeat validation starts its own producer.\n' >&2
  exit 1
fi

sh Scripts/Support/build-shared-memory-producer.sh >/tmp/mca-coreaudiod-stale-producer-build.log
sh Scripts/Support/build-capture-mixed-capture-audio.sh >/tmp/mca-coreaudiod-stale-capture-build.log

Build/Debug/Tools/SharedMemoryProducer --freeze-heartbeat >/tmp/mca-coreaudiod-stale-producer.log 2>&1 &
producer_pid=$!
trap 'kill "$producer_pid" >/dev/null 2>&1 || true; wait "$producer_pid" >/dev/null 2>&1 || true' EXIT

sleep 1
Build/Debug/Tools/CaptureMixedCaptureAudio --frames 4800 --timeout-ms 5000 --expect silence

printf 'Core Audio stale-heartbeat silence validation passed\n'
