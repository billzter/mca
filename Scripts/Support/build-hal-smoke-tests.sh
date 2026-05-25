#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

BUILD_CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_DIR="${BUILD_DIR:-Build/$BUILD_CONFIGURATION}"
OUTPUT_DIR="$BUILD_DIR/Tools"

mkdir -p "$OUTPUT_DIR"

clang \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -IHALPlugin/Include \
  -framework CoreAudio \
  -framework CoreFoundation \
  Tools/HALDriverSmokeTests/MixedCaptureAudioDriverSmokeTests.c \
  -o "$OUTPUT_DIR/MixedCaptureAudioDriverSmokeTests"

printf 'built %s\n' "$OUTPUT_DIR/MixedCaptureAudioDriverSmokeTests"
