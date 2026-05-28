#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_PATH="/Applications/MixedCaptureAudio.app"
DRIVER_DIR="/Library/Audio/Plug-Ins/HAL"
DRIVER_PATH="$DRIVER_DIR/MixedCaptureAudio.driver"

usage() {
  cat <<'USAGE'
Usage: Scripts/manage-installation.sh <command> [args]

Commands:
  install-driver [driver-path]  Install a built HAL driver. Defaults to Build/Debug/MixedCaptureAudio.driver.
  uninstall-driver             Remove the installed HAL driver only.
  uninstall                    Remove the installed app and HAL driver. Preferences and privacy permissions stay intact.
  reload-coreaudio             Restart Core Audio driver hosts for local driver testing.
USAGE
}

install_driver() {
  source_driver="${1:-Build/Debug/MixedCaptureAudio.driver}"

  if [ ! -d "$source_driver" ]; then
    printf 'driver bundle not found: %s\n' "$source_driver" >&2
    printf 'build the MixedCaptureAudioDriver Xcode scheme first\n' >&2
    exit 1
  fi

  printf 'Installing %s to %s\n' "$source_driver" "$DRIVER_PATH"
  sudo mkdir -p "$DRIVER_DIR"
  sudo rm -rf "$DRIVER_PATH"
  sudo cp -R "$source_driver" "$DRIVER_PATH"
  sudo chown -R root:wheel "$DRIVER_PATH"
  sudo find "$DRIVER_PATH" -type d -exec chmod 755 {} +
  sudo find "$DRIVER_PATH" -type f -exec chmod 644 {} +
  sudo chmod 755 "$DRIVER_PATH/Contents/MacOS/MixedCaptureAudio"
  codesign --verify --deep --strict --verbose=2 "$DRIVER_PATH"

  printf 'Installed. Restart the Mac if MCA still reports Restart required.\n'
  printf 'Developer shortcut: Scripts/manage-installation.sh reload-coreaudio can reload Core Audio during local testing.\n'
}

uninstall_driver() {
  if [ ! -e "$DRIVER_PATH" ]; then
    printf 'driver is not installed: %s\n' "$DRIVER_PATH"
    return 0
  fi

  printf 'Removing %s\n' "$DRIVER_PATH"
  sudo rm -rf "$DRIVER_PATH"

  if [ -e "$DRIVER_PATH" ]; then
    printf 'Failed to remove %s\n' "$DRIVER_PATH" >&2
    exit 1
  fi

  printf 'Removed. Restart the Mac if Mixed Capture Audio remains visible in audio apps.\n'
}

uninstall_all() {
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
    spotlight_matches="$(mdfind 'kMDItemCFBundleIdentifier == "com.minamiktr.mca"' 2>/dev/null || true)"
    if [ "$spotlight_matches" != "" ]; then
      printf 'Spotlight still has MCA app metadata cached:\n%s\n' "$spotlight_matches"
      printf 'If the app is gone from /Applications, wait for Spotlight to refresh or run: mdutil -E /\n'
    fi
  fi

  dev_app_copies="$(
    find "$HOME/Documents" /private/tmp \
      -name MixedCaptureAudio.app \
      -type d \
      -maxdepth 8 \
      -print 2>/dev/null || true
  )"
  if [ "$dev_app_copies" != "" ]; then
    printf 'Non-installed development/test MCA app copies still exist and may appear in Spotlight:\n%s\n' "$dev_app_copies"
    printf 'These are not the /Applications install. Remove build/test artifacts if you want Spotlight to stop launching them.\n'
  fi

  printf 'Uninstall complete. Restart the Mac if Mixed Capture Audio remains visible in audio apps.\n'
}

reload_coreaudio() {
  printf 'Reloading Core Audio driver hosts. Active audio sessions may be interrupted.\n'

  printf 'Stopping Core Audio driver service helper if it is running...\n'
  sudo pkill -TERM -f 'com.apple.audio.Core-Audio-Driver-Service.helper' 2>/dev/null || true
  sudo pkill -TERM -f 'Core-Audio-Driver-Service.helper' 2>/dev/null || true

  printf 'Stopping coreaudiod...\n'
  sudo killall coreaudiod

  printf 'Core Audio reload requested. Reopen audio clients, then refresh MCA.\n'
}

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 2
fi

command="$1"
shift

case "$command" in
  install-driver)
    install_driver "${1:-}"
    ;;
  uninstall-driver)
    uninstall_driver
    ;;
  uninstall)
    uninstall_all
    ;;
  reload-coreaudio)
    reload_coreaudio
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    printf 'unknown command: %s\n\n' "$command" >&2
    usage >&2
    exit 2
    ;;
esac
