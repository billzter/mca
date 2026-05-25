#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_PATH="${1:-Build/Debug/mixed-wav-self-test.wav}"

Scripts/Support/build-mixed-wav-proof.sh
Build/Debug/MixedWavProof.app/Contents/MacOS/MixedWavProof --self-test --output "$OUTPUT_PATH"

printf 'mixed WAV self-test passed: %s\n' "$OUTPUT_PATH"
