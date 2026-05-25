#!/bin/sh
set -eu

TARGET_DRIVER="/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver"

if [ ! -e "$TARGET_DRIVER" ]; then
  printf 'driver is not installed: %s\n' "$TARGET_DRIVER"
  exit 0
fi

printf 'Removing %s\n' "$TARGET_DRIVER"
sudo rm -rf "$TARGET_DRIVER"
printf 'Removed. Restart the Mac if Mixed Capture Audio remains visible in audio apps.\n'
