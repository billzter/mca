#!/bin/sh
set -eu

APP_PATH="/Applications/MixedCaptureAudio.app"
DRIVER_PATH="/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver"

printf 'Uninstalling MixedCaptureAudio app and HAL driver.\n'
printf 'Preferences and macOS privacy permissions will be preserved.\n'

if [ -d "$APP_PATH" ]; then
  printf 'Removing %s\n' "$APP_PATH"
  sudo rm -rf "$APP_PATH"
else
  printf 'App is not installed at %s\n' "$APP_PATH"
fi

if [ -e "$APP_PATH" ]; then
  printf 'Failed to remove %s\n' "$APP_PATH" >&2
  exit 1
fi

if [ -d "$DRIVER_PATH" ]; then
  printf 'Removing %s\n' "$DRIVER_PATH"
  sudo rm -rf "$DRIVER_PATH"
else
  printf 'Driver is not installed at %s\n' "$DRIVER_PATH"
fi

if [ -e "$DRIVER_PATH" ]; then
  printf 'Failed to remove %s\n' "$DRIVER_PATH" >&2
  exit 1
fi

if command -v mdfind >/dev/null 2>&1; then
  SPOTLIGHT_MATCHES="$(mdfind 'kMDItemCFBundleIdentifier == "com.minamiktr.mca"' 2>/dev/null || true)"
  if [ "$SPOTLIGHT_MATCHES" != "" ]; then
    printf 'Spotlight still has MCA app metadata cached:\n%s\n' "$SPOTLIGHT_MATCHES"
    printf 'If the app is gone from /Applications, wait for Spotlight to refresh or run: mdutil -E /\n'
  fi
fi

DEV_APP_COPIES="$(
  find "$HOME/Documents" /private/tmp \
    -name MixedCaptureAudio.app \
    -type d \
    -maxdepth 8 \
    -print 2>/dev/null || true
)"
if [ "$DEV_APP_COPIES" != "" ]; then
  printf 'Non-installed development/test MCA app copies still exist and may appear in Spotlight:\n%s\n' "$DEV_APP_COPIES"
  printf 'These are not the /Applications install. Remove build/test artifacts if you want Spotlight to stop launching them.\n'
fi

printf 'Uninstall complete. Restart the Mac if Mixed Capture Audio remains visible in audio apps.\n'
