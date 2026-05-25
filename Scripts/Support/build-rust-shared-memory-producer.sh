#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR/Rust/mixed-audio-engine"

BUILD_CONFIGURATION="${CONFIGURATION:-Debug}"
if [ "$BUILD_CONFIGURATION" = "Release" ]; then
  CARGO_FLAGS="--release"
  PROFILE_DIR="release"
else
  CARGO_FLAGS=""
  PROFILE_DIR="debug"
fi

cargo build --bin rust-shared-memory-producer $CARGO_FLAGS

OUTPUT_DIR="$ROOT_DIR/Build/$BUILD_CONFIGURATION/Tools"
mkdir -p "$OUTPUT_DIR"
cp "target/$PROFILE_DIR/rust-shared-memory-producer" "$OUTPUT_DIR/RustSharedMemoryProducer"

printf 'built %s\n' "$OUTPUT_DIR/RustSharedMemoryProducer"
