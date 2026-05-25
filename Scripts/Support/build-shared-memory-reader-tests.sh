#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

BUILD_CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_DIR="${BUILD_DIR:-Build/$BUILD_CONFIGURATION}"
TOOLS_DIR="$BUILD_DIR/Tools"

mkdir -p "$TOOLS_DIR"

clang \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -IHALPlugin/Include \
  Tools/SharedMemoryReaderTests/MixedAudioSharedMemoryReaderTests.c \
  HALPlugin/Sources/MixedAudioSharedMemoryReader.c \
  -o "$TOOLS_DIR/MixedAudioSharedMemoryReaderTests"

printf 'built %s\n' "$TOOLS_DIR/MixedAudioSharedMemoryReaderTests"
