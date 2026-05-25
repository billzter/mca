#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${CONFIGURATION:-Release}"
APP_DIR="Build/$CONFIGURATION/MixedCaptureAudio.app"
DRIVER_DIR="Build/$CONFIGURATION/MixedCaptureAudio.driver"
PACKAGE_DIR="Build/Packages"
STAGING_ROOT="Build/PackageRoot"
COMPONENT_PLIST="Packaging/MixedCaptureAudioComponentProperties.plist"
PAYLOAD_VERIFY_ROOT="Build/PackageVerify"

export COPYFILE_DISABLE=1

CONFIGURATION="$CONFIGURATION" Scripts/build-app.sh
CONFIGURATION="$CONFIGURATION" Scripts/build-hal-driver.sh
codesign --verify --deep --strict --verbose=4 "$APP_DIR" >/dev/null
codesign --verify --deep --strict --verbose=4 "$DRIVER_DIR" >/dev/null

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_DIR/Contents/Info.plist")"
PACKAGE_PATH="$PACKAGE_DIR/MixedCaptureAudio-$APP_VERSION.pkg"

rm -rf "$STAGING_ROOT"
mkdir -p "$STAGING_ROOT/Applications" "$STAGING_ROOT/Library/Audio/Plug-Ins/HAL" "$PACKAGE_DIR"

ditto --norsrc --noextattr "$APP_DIR" "$STAGING_ROOT/Applications/MixedCaptureAudio.app"
ditto --norsrc --noextattr "$DRIVER_DIR" "$STAGING_ROOT/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver"
xattr -cr "$STAGING_ROOT" 2>/dev/null || true

PKGBUILD_ARGS="
--root $STAGING_ROOT
--identifier com.minamiktr.mca.pkg
--version $APP_VERSION
--install-location /
--ownership recommended
--component-plist $COMPONENT_PLIST
--filter (^|/)\\._[^/]*$
--filter (^|/)\\.DS_Store$
"

if [ "${INSTALLER_SIGN_IDENTITY:-}" != "" ]; then
  if [ "${INSTALLER_SIGN_KEYCHAIN:-}" != "" ]; then
    # shellcheck disable=SC2086
    pkgbuild $PKGBUILD_ARGS --sign "$INSTALLER_SIGN_IDENTITY" --keychain "$INSTALLER_SIGN_KEYCHAIN" "$PACKAGE_PATH"
  else
    # shellcheck disable=SC2086
    pkgbuild $PKGBUILD_ARGS --sign "$INSTALLER_SIGN_IDENTITY" "$PACKAGE_PATH"
  fi
else
  # shellcheck disable=SC2086
  pkgbuild $PKGBUILD_ARGS "$PACKAGE_PATH"
fi

pkgutil --check-signature "$PACKAGE_PATH" >/dev/null 2>&1 || {
  if [ "${INSTALLER_SIGN_IDENTITY:-}" != "" ]; then
    printf 'package signature verification failed: %s\n' "$PACKAGE_PATH" >&2
    exit 1
  fi
}

rm -rf "$PAYLOAD_VERIFY_ROOT"
pkgutil --expand-full "$PACKAGE_PATH" "$PAYLOAD_VERIFY_ROOT"
if grep -q '<relocate>' "$PAYLOAD_VERIFY_ROOT/PackageInfo"; then
  printf 'package metadata allows bundle relocation: %s\n' "$PACKAGE_PATH" >&2
  exit 1
fi
if ! grep -q '<strict-identifier>' "$PAYLOAD_VERIFY_ROOT/PackageInfo"; then
  printf 'package metadata missing strict bundle identifiers: %s\n' "$PACKAGE_PATH" >&2
  exit 1
fi
rm -rf "$PAYLOAD_VERIFY_ROOT"

printf 'built %s\n' "$PACKAGE_PATH"
printf 'Installer updates app and HAL driver only. Restart the Mac if MCA reports Restart required after installation.\n'
