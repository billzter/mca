#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

SECONDS_TO_CAPTURE="${1:-30}"
REPORT_PATH="${2:-TestArtifacts/cadence-report.txt}"
WAV_PATH="${3:-${REPORT_PATH%.txt}.wav}"

mkdir -p "$(dirname "$REPORT_PATH")"
mkdir -p "$(dirname "$WAV_PATH")"

Scripts/Support/build-mixed-wav-proof.sh
Build/Debug/MixedWavProof.app/Contents/MacOS/MixedWavProof \
  --seconds "$SECONDS_TO_CAPTURE" \
  --cadence-report "$REPORT_PATH" \
  --output "$WAV_PATH"

printf 'cadence proof validation passed: %s\n' "$REPORT_PATH"
printf 'cadence proof companion WAV: %s\n' "$WAV_PATH"
