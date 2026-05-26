#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'signing config validation failed: %s\n' "$1" >&2
  exit 1
}

sh -n Scripts/build-app.sh \
  Scripts/build-hal-driver.sh \
  Scripts/package-installer.sh \
  Scripts/package-signed-installer.sh \
  Scripts/install-public-signing-certs.sh \
  Scripts/diagnose-release-signing.sh

test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' App/MixedCaptureAudio.entitlements)" = "true" ||
  fail "app signing entitlements do not allow microphone input under hardened runtime"

unset MCA_P12_PASSWORD
unset MCA_APP_P12_PASSWORD
unset MCA_INSTALLER_P12_PASSWORD
if Scripts/package-signed-installer.sh >/tmp/mca-signing-missing-password.log 2>&1; then
  fail "signed package wrapper succeeded without a p12 password"
fi
grep -q 'set MCA_APP_P12_PASSWORD or MCA_P12_PASSWORD' /tmp/mca-signing-missing-password.log ||
  fail "signed package wrapper did not fail with the expected password guidance"

if grep -E '^[[:space:]]*-A([[:space:]]|\\$)' Scripts/package-signed-installer.sh >/dev/null; then
  fail "signed package wrapper grants broad private-key access with security import -A"
fi

printf 'signing config validation passed\n'
