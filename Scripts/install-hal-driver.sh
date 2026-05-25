#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

SOURCE_DRIVER="${1:-Build/Debug/MixedCaptureAudio.driver}"
TARGET_DIR="/Library/Audio/Plug-Ins/HAL"
TARGET_DRIVER="$TARGET_DIR/MixedCaptureAudio.driver"

if [ ! -d "$SOURCE_DRIVER" ]; then
  printf 'driver bundle not found: %s\n' "$SOURCE_DRIVER" >&2
  printf 'run Scripts/build-hal-driver.sh first\n' >&2
  exit 1
fi

printf 'Installing %s to %s\n' "$SOURCE_DRIVER" "$TARGET_DRIVER"
sudo mkdir -p "$TARGET_DIR"
sudo rm -rf "$TARGET_DRIVER"
sudo cp -R "$SOURCE_DRIVER" "$TARGET_DRIVER"
sudo chown -R root:wheel "$TARGET_DRIVER"
sudo find "$TARGET_DRIVER" -type d -exec chmod 755 {} +
sudo find "$TARGET_DRIVER" -type f -exec chmod 644 {} +
sudo chmod 755 "$TARGET_DRIVER/Contents/MacOS/MixedCaptureAudio"
codesign --verify --deep --strict --verbose=2 "$TARGET_DRIVER"

printf 'Installed. Restart the Mac if MCA still reports Restart required.\n'
printf 'Developer shortcut: Scripts/reload-coreaudio.sh can reload Core Audio during local testing.\n'
