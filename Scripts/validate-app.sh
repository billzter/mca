#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

Scripts/validate-app-model.sh
Scripts/build-app.sh

test -x Build/Debug/MixedCaptureAudio.app/Contents/MacOS/MixedCaptureAudio
otool -l Build/Debug/MixedCaptureAudio.app/Contents/MacOS/MixedCaptureAudio | grep -q 'minos 14.2'
test "$(plutil -extract LSUIElement raw -o - Build/Debug/MixedCaptureAudio.app/Contents/Info.plist)" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' App/MixedCaptureAudio.entitlements)" = "true"
codesign --verify Build/Debug/MixedCaptureAudio.app

printf 'app validation passed\n'
