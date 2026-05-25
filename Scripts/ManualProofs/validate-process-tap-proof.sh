#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

SECONDS_TO_CAPTURE="${1:-5}"

Scripts/Support/build-process-tap-proof.sh
Build/Debug/ProcessTapProof.app/Contents/MacOS/ProcessTapProof --seconds "$SECONDS_TO_CAPTURE"

printf 'process-tap proof validation passed\n'
