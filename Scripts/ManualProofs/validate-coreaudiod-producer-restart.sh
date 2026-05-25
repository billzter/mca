#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if pgrep -qx SharedMemoryProducer >/dev/null 2>&1; then
  printf 'SharedMemoryProducer is already running. Stop it before this restart validation starts its own producers.\n' >&2
  exit 1
fi

sh Scripts/Support/build-shared-memory-producer.sh >/tmp/mca-coreaudiod-restart-producer-build.log
sh Scripts/Support/build-capture-mixed-capture-audio.sh >/tmp/mca-coreaudiod-restart-capture-build.log

start_producer() {
  Build/Debug/Tools/SharedMemoryProducer >/tmp/mca-coreaudiod-restart-producer.log 2>&1 &
  producer_pid=$!
  sleep 1
}

stop_producer() {
  kill "$producer_pid" >/dev/null 2>&1 || true
  wait "$producer_pid" >/dev/null 2>&1 || true
}

producer_pid=
trap 'if [ -n "${producer_pid:-}" ]; then stop_producer; fi' EXIT

start_producer
Build/Debug/Tools/CaptureMixedCaptureAudio --frames 4800 --timeout-ms 5000 --expect marker
stop_producer
producer_pid=

sleep 1

start_producer
Build/Debug/Tools/CaptureMixedCaptureAudio --frames 4800 --timeout-ms 5000 --expect marker

printf 'Core Audio producer-restart validation passed\n'
