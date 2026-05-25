#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

BUILD_CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_DIR="${BUILD_DIR:-Build/$BUILD_CONFIGURATION}"
TOOLS_DIR="$BUILD_DIR/Tools"
APP_DIR="$BUILD_DIR/ProcessTapProof.app"
APP_CONTENTS_DIR="$APP_DIR/Contents"
APP_MACOS_DIR="$APP_CONTENTS_DIR/MacOS"

mkdir -p "$TOOLS_DIR" "$APP_MACOS_DIR"
cp Tools/ProcessTapProof/Info.plist "$APP_CONTENTS_DIR/Info.plist"

clang \
  -fobjc-arc \
  -Wall \
  -Wextra \
  -Werror \
  -framework CoreAudio \
  -framework CoreFoundation \
  -framework Foundation \
  Tools/ProcessTapProof/ProcessTapProof.m \
  -o "$APP_MACOS_DIR/ProcessTapProof"

codesign --force --sign - "$APP_DIR" >/dev/null

rm -f "$TOOLS_DIR/ProcessTapProof"
ln -s "../ProcessTapProof.app/Contents/MacOS/ProcessTapProof" "$TOOLS_DIR/ProcessTapProof"

printf 'built %s\n' "$APP_MACOS_DIR/ProcessTapProof"
