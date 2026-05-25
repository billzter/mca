#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'packaging validation failed: %s\n' "$1" >&2
  exit 1
}

sh -n Scripts/package-installer.sh Scripts/package-signed-installer.sh Scripts/uninstall-mca.sh
plutil -lint Packaging/MixedCaptureAudioComponentProperties.plist >/tmp/mca-component-plist.txt

CONFIGURATION=Release Scripts/package-installer.sh >/tmp/mca-package.log

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - App/Resources/Info.plist)"
PACKAGE_PATH="Build/Packages/MixedCaptureAudio-$APP_VERSION.pkg"

test -f "$PACKAGE_PATH" || fail "package was not created: $PACKAGE_PATH"

pkgutil --payload-files "$PACKAGE_PATH" | sed 's#^\./##' >/tmp/mca-package-payload.txt

grep -q '^Applications/MixedCaptureAudio.app/Contents/Info.plist$' /tmp/mca-package-payload.txt ||
  fail "package payload missing app Info.plist"
grep -q '^Applications/MixedCaptureAudio.app/Contents/MacOS/MixedCaptureAudio$' /tmp/mca-package-payload.txt ||
  fail "package payload missing app executable"
grep -q '^Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver/Contents/Info.plist$' /tmp/mca-package-payload.txt ||
  fail "package payload missing driver Info.plist"
grep -q '^Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver/Contents/MacOS/MixedCaptureAudio$' /tmp/mca-package-payload.txt ||
  fail "package payload missing driver executable"

INSPECT_ROOT="/tmp/mca-package-inspect"
rm -rf "$INSPECT_ROOT"
pkgutil --expand-full "$PACKAGE_PATH" "$INSPECT_ROOT"

if grep -q '<relocate>' "$INSPECT_ROOT/PackageInfo"; then
  fail "package metadata allows bundle relocation"
fi
if ! grep -q '<strict-identifier>' "$INSPECT_ROOT/PackageInfo"; then
  fail "package metadata missing strict bundle identifiers"
fi

printf 'packaging validation passed: %s\n' "$PACKAGE_PATH"
