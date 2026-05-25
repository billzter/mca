#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

SECONDS_TO_CAPTURE="${1:-10}"
OUTPUT_PATH="${2:-TestArtifacts/mixed-wav-proof.wav}"

mkdir -p "$(dirname "$OUTPUT_PATH")"

Scripts/Support/build-mixed-wav-proof.sh
Build/Debug/MixedWavProof.app/Contents/MacOS/MixedWavProof \
  --seconds "$SECONDS_TO_CAPTURE" \
  --output "$OUTPUT_PATH"

printf 'mixed WAV proof validation passed: %s\n' "$OUTPUT_PATH"
