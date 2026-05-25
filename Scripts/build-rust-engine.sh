#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR/Rust/mixed-audio-engine"

BUILD_CONFIGURATION="${CONFIGURATION:-Debug}"
if [ "$BUILD_CONFIGURATION" = "Release" ]; then
  CARGO_FLAGS="--release"
  PROFILE_DIR="release"
  OUTPUT_LIB_DIR="$ROOT_DIR/Generated/lib/release"
else
  CARGO_FLAGS=""
  PROFILE_DIR="debug"
  OUTPUT_LIB_DIR="$ROOT_DIR/Generated/lib/debug"
fi

"$ROOT_DIR/Scripts/generate-rust-shared-memory-abi.sh"
cargo build $CARGO_FLAGS

mkdir -p "$ROOT_DIR/Generated/include" "$OUTPUT_LIB_DIR"
cp include/MixedAudioEngine.h "$ROOT_DIR/Generated/include/MixedAudioEngine.h"
cp "target/$PROFILE_DIR/libmixed_audio_engine.a" "$OUTPUT_LIB_DIR/libmixed_audio_engine.a"

printf 'built %s\n' "$OUTPUT_LIB_DIR/libmixed_audio_engine.a"
printf 'copied %s\n' "$ROOT_DIR/Generated/include/MixedAudioEngine.h"
