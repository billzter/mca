#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

BUILD_CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_DIR="${BUILD_DIR:-Build/$BUILD_CONFIGURATION}"
TOOLS_DIR="$BUILD_DIR/Tools"
APP_DIR="$BUILD_DIR/MixedWavProof.app"
APP_CONTENTS_DIR="$APP_DIR/Contents"
APP_MACOS_DIR="$APP_CONTENTS_DIR/MacOS"

mkdir -p "$TOOLS_DIR" "$APP_MACOS_DIR"
cp Tools/MixedWavProof/Info.plist "$APP_CONTENTS_DIR/Info.plist"

Scripts/build-rust-engine.sh >/tmp/mca-mixed-wav-proof-rust-build.log

clang \
  -fobjc-arc \
  -Wall \
  -Wextra \
  -Werror \
  -IGenerated/include \
  -IHALPlugin/Include \
  -framework AudioToolbox \
  -framework CoreAudio \
  -framework CoreFoundation \
  -framework Foundation \
  Tools/MixedWavProof/MixedWavProof.m \
  Generated/lib/debug/libmixed_audio_engine.a \
  -o "$APP_MACOS_DIR/MixedWavProof"

codesign --force --sign - "$APP_DIR" >/dev/null

rm -f "$TOOLS_DIR/MixedWavProof"
ln -s "../MixedWavProof.app/Contents/MacOS/MixedWavProof" "$TOOLS_DIR/MixedWavProof"

printf 'built %s\n' "$APP_MACOS_DIR/MixedWavProof"
