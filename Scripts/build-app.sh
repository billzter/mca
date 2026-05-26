#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${CONFIGURATION:-Debug}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.2}"
export MACOSX_DEPLOYMENT_TARGET
SWIFT_TARGET_TRIPLE="$(uname -m)-apple-macosx$MACOSX_DEPLOYMENT_TARGET"
APP_DIR="Build/$CONFIGURATION/MixedCaptureAudio.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
RUST_PROFILE_DIR="debug"
if [ "$CONFIGURATION" = "Release" ]; then
  RUST_PROFILE_DIR="release"
fi
SIGN_IDENTITY="${APP_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"

CONFIGURATION="$CONFIGURATION" Scripts/build-rust-engine.sh

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" Build/ModuleCache
cp App/Resources/Info.plist "$APP_DIR/Contents/Info.plist"
if [ "${MCA_VERSION:-}" != "" ]; then
  plutil -replace CFBundleShortVersionString -string "$MCA_VERSION" "$APP_DIR/Contents/Info.plist"
fi
if [ "${MCA_BUILD_NUMBER:-}" != "" ]; then
  plutil -replace CFBundleVersion -string "$MCA_BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
fi

mkdir -p "Build/$CONFIGURATION/Objects"
clang \
  -fobjc-arc \
  -Wall \
  -Wextra \
  -Werror \
  -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
  -c App/Sources/SystemAudio/SystemAudioAccessProbe.m \
  -o "Build/$CONFIGURATION/Objects/SystemAudioAccessProbe.o"

clang \
  -fobjc-arc \
  -Wall \
  -Wextra \
  -Werror \
  -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
  -I App/Sources/Audio \
  -I HALPlugin/Include \
  -I Generated/include \
  -c App/Sources/Audio/LiveMixerSession.m \
  -o "Build/$CONFIGURATION/Objects/LiveMixerSession.o"

swiftc \
  -module-cache-path Build/ModuleCache \
  -target "$SWIFT_TARGET_TRIPLE" \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework ServiceManagement \
  App/Sources/Diagnostics/HealthDiagnostics.swift \
  App/Sources/App/PrerequisiteStatus.swift \
  App/Sources/App/SetupPresentation.swift \
  App/Sources/App/AppPrerequisiteChecker.swift \
  App/Sources/App/MicrophonePermissionRequester.swift \
  App/Sources/App/SystemAudioAccessTester.swift \
  App/Sources/App/LaunchAtStartupController.swift \
  App/Sources/App/DebouncedMainActorAction.swift \
  App/Sources/App/AppLiveMixerController.swift \
  App/Sources/App/AppStatusModel.swift \
  App/Sources/App/AppServices.swift \
  App/Sources/App/MixedCaptureAudioApp.swift \
  App/Sources/App/StatusMenuView.swift \
  App/Sources/App/SetupView.swift \
  "Build/$CONFIGURATION/Objects/SystemAudioAccessProbe.o" \
  "Build/$CONFIGURATION/Objects/LiveMixerSession.o" \
  "Generated/lib/$RUST_PROFILE_DIR/libmixed_audio_engine.a" \
  -o "$MACOS_DIR/MixedCaptureAudio"

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP_DIR" >/dev/null
else
  if [ "${CODESIGN_KEYCHAIN:-}" != "" ]; then
    codesign \
      --force \
      --sign "$SIGN_IDENTITY" \
      --keychain "$CODESIGN_KEYCHAIN" \
      --timestamp \
      --options runtime \
      --entitlements App/MixedCaptureAudio.entitlements \
      "$APP_DIR" >/dev/null
  else
    codesign \
      --force \
      --sign "$SIGN_IDENTITY" \
      --timestamp \
      --options runtime \
      --entitlements App/MixedCaptureAudio.entitlements \
      "$APP_DIR" >/dev/null
  fi
fi
codesign --verify --deep --strict --verbose=4 "$APP_DIR" >/dev/null
printf 'built %s\n' "$APP_DIR"
