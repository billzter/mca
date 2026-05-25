#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

BUILD_CONFIGURATION="${CONFIGURATION:-Debug}"

if pgrep -qx SharedMemoryProducer >/dev/null 2>&1 ||
   pgrep -qx RustSharedMemoryProducer >/dev/null 2>&1 ||
   pgrep -qx MixedWavProof >/dev/null 2>&1; then
  printf 'A shared-memory producer is already running. Stop it before this validation uses /mca.mix.v1.\n' >&2
  exit 1
fi

sh Scripts/Support/build-rust-shared-memory-producer.sh >/tmp/mca-rust-shm-producer-build.log

OUTPUT_PATH="/tmp/mca-rust-shm-producer-once.log"
"Build/$BUILD_CONFIGURATION/Tools/RustSharedMemoryProducer" --once >"$OUTPUT_PATH"

grep 'created /mca.mix.v1' "$OUTPUT_PATH" >/dev/null
grep 'header version=1 sample_rate=48000 channels=2' "$OUTPUT_PATH" >/dev/null
grep 'marker left=0.25 right=-0.25' "$OUTPUT_PATH" >/dev/null
grep 'removed /mca.mix.v1' "$OUTPUT_PATH" >/dev/null

printf 'Rust shared-memory producer validation passed\n'
