#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_DIR="${BUILD_DIR:-Build/$BUILD_CONFIGURATION}"
PRODUCT_DIR="$BUILD_DIR/MixedCaptureAudio.driver"
EXECUTABLE_DIR="$PRODUCT_DIR/Contents/MacOS"
INFO_PLIST_DIR="$PRODUCT_DIR/Contents"
SIGN_IDENTITY="${DRIVER_SIGN_IDENTITY:-${APP_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}}"

rm -rf "$PRODUCT_DIR"
mkdir -p "$EXECUTABLE_DIR"

clang \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -fvisibility=hidden \
  -bundle \
  -IHALPlugin/Include \
  -framework CoreAudio \
  -framework CoreFoundation \
  HALPlugin/Sources/MixedCaptureAudioDriver.c \
  HALPlugin/Sources/MixedAudioSharedMemoryReader.c \
  HALPlugin/Sources/MixedAudioSharedMemoryProbe.c \
  -o "$EXECUTABLE_DIR/MixedCaptureAudio"

cp HALPlugin/Resources/Info.plist "$INFO_PLIST_DIR/Info.plist"
if [ "${MCA_VERSION:-}" != "" ]; then
  plutil -replace CFBundleShortVersionString -string "$MCA_VERSION" "$INFO_PLIST_DIR/Info.plist"
fi
if [ "${MCA_BUILD_NUMBER:-}" != "" ]; then
  plutil -replace CFBundleVersion -string "$MCA_BUILD_NUMBER" "$INFO_PLIST_DIR/Info.plist"
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$PRODUCT_DIR" >/dev/null 2>&1
else
  if [ "${CODESIGN_KEYCHAIN:-}" != "" ]; then
    codesign \
      --force \
      --sign "$SIGN_IDENTITY" \
      --keychain "$CODESIGN_KEYCHAIN" \
      --timestamp \
      "$PRODUCT_DIR" >/dev/null
  else
    codesign \
      --force \
      --sign "$SIGN_IDENTITY" \
      --timestamp \
      "$PRODUCT_DIR" >/dev/null
  fi
fi

codesign --verify --deep --strict --verbose=4 "$PRODUCT_DIR" >/dev/null
printf 'built %s\n' "$PRODUCT_DIR"
