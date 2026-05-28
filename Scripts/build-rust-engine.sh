#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR/Rust/mixed-audio-engine"

BUILD_CONFIGURATION="${CONFIGURATION:-Debug}"
if [ "$BUILD_CONFIGURATION" = "Release" ]; then
  PROFILE_DIR="release"
  OUTPUT_LIB_DIR="$ROOT_DIR/Generated/lib/release"
else
  CARGO_FLAGS=""
  PROFILE_DIR="debug"
  OUTPUT_LIB_DIR="$ROOT_DIR/Generated/lib/debug"
fi

"$ROOT_DIR/Scripts/generate-rust-shared-memory-abi.sh"

mkdir -p "$ROOT_DIR/Generated/include" "$OUTPUT_LIB_DIR"
cp include/MixedAudioEngine.h "$ROOT_DIR/Generated/include/MixedAudioEngine.h"

if [ "$BUILD_CONFIGURATION" = "Release" ]; then
  for target in aarch64-apple-darwin x86_64-apple-darwin; do
    if ! cargo build --release --target "$target"; then
      printf 'failed to build Rust engine for %s; install it with: rustup target add %s\n' "$target" "$target" >&2
      exit 1
    fi
  done

  lipo -create \
    "target/aarch64-apple-darwin/$PROFILE_DIR/libmixed_audio_engine.a" \
    "target/x86_64-apple-darwin/$PROFILE_DIR/libmixed_audio_engine.a" \
    -output "$OUTPUT_LIB_DIR/libmixed_audio_engine.a"
else
  cargo build $CARGO_FLAGS
  cp "target/$PROFILE_DIR/libmixed_audio_engine.a" "$OUTPUT_LIB_DIR/libmixed_audio_engine.a"
fi

printf 'built %s\n' "$OUTPUT_LIB_DIR/libmixed_audio_engine.a"
printf 'copied %s\n' "$ROOT_DIR/Generated/include/MixedAudioEngine.h"
