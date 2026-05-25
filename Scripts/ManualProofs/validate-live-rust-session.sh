#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

SECONDS_TO_CAPTURE="${1:-10}"

Scripts/Support/build-mixed-wav-proof.sh
Scripts/Support/build-audio-device-list.sh >/tmp/mca-live-rust-device-list-build.log
Scripts/Support/build-capture-mixed-capture-audio.sh >/tmp/mca-live-rust-capture-build.log

if ! Build/Debug/Tools/ListAudioDevices | grep 'Mixed Capture Audio' >/tmp/mca-live-rust-device-list-check.log; then
  printf 'Mixed Capture Audio is not visible. Install the HAL driver and restart coreaudiod first.\n' >&2
  exit 1
fi

Build/Debug/MixedWavProof.app/Contents/MacOS/MixedWavProof \
  --seconds "$SECONDS_TO_CAPTURE" \
  --rust-session-shm >/tmp/mca-live-rust-session.log 2>&1 &
producer_pid=$!
trap 'kill "$producer_pid" >/dev/null 2>&1 || true; wait "$producer_pid" >/dev/null 2>&1 || true' EXIT

ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep 'rust_session_shm active' /tmp/mca-live-rust-session.log >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$producer_pid" >/dev/null 2>&1; then
    cat /tmp/mca-live-rust-session.log >&2
    printf 'MixedWavProof exited before Rust session became active.\n' >&2
    exit 1
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  cat /tmp/mca-live-rust-session.log >&2
  printf 'Timed out waiting for Rust session shared memory to become active.\n' >&2
  exit 1
fi

Build/Debug/Tools/CaptureMixedCaptureAudio --frames 4800 --timeout-ms 5000 --expect nonzero
wait "$producer_pid"
trap - EXIT

printf 'live Rust session validation passed\n'
