#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'notarization failed: %s\n' "$1" >&2
  exit 1
}

CONFIGURATION="${CONFIGURATION:-Release}"
APP_DIR="Build/$CONFIGURATION/MixedCaptureAudio.app"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_DIR/Contents/Info.plist" 2>/dev/null || true)"
PACKAGE_PATH="${MCA_NOTARY_PACKAGE_PATH:-}"
if [ "$PACKAGE_PATH" = "" ]; then
  test "$APP_VERSION" != "" || fail "could not resolve package version from $APP_DIR"
  PACKAGE_PATH="Build/Packages/MixedCaptureAudio-$APP_VERSION.pkg"
fi
LOG_DIR="${MCA_NOTARY_LOG_DIR:-Build/Notarization}"
SUBMIT_OUTPUT_PLIST="$LOG_DIR/notary-submit.plist"
NOTARY_LOG_PATH="$LOG_DIR/notary-log.json"

NOTARY_KEY_PATH="${MCA_NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${MCA_NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${MCA_NOTARY_ISSUER_ID:-}"
TEAM_ID="${MCA_TEAM_ID:-}"

test -f "$PACKAGE_PATH" || fail "missing signed package: $PACKAGE_PATH"
test -f "$NOTARY_KEY_PATH" || fail "missing App Store Connect API key file: set MCA_NOTARY_KEY_PATH"
test "$NOTARY_KEY_ID" != "" || fail "set MCA_NOTARY_KEY_ID"
test "$NOTARY_ISSUER_ID" != "" || fail "set MCA_NOTARY_ISSUER_ID"
test "$TEAM_ID" != "" || fail "set MCA_TEAM_ID"
pkgutil --check-signature "$PACKAGE_PATH" >/dev/null ||
  fail "package is not signed by a trusted installer identity: $PACKAGE_PATH"

mkdir -p "$LOG_DIR"

printf 'submitting %s for notarization\n' "$PACKAGE_PATH"
xcrun notarytool submit "$PACKAGE_PATH" \
  --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --team-id "$TEAM_ID" \
  --wait \
  --output-format plist \
  >"$SUBMIT_OUTPUT_PLIST"

SUBMISSION_ID="$(plutil -extract id raw -o - "$SUBMIT_OUTPUT_PLIST" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw -o - "$SUBMIT_OUTPUT_PLIST" 2>/dev/null || true)"

printf 'notarization submission id=%s status=%s\n' "${SUBMISSION_ID:-unknown}" "${STATUS:-unknown}"

if [ "$STATUS" != "Accepted" ]; then
  if [ "$SUBMISSION_ID" != "" ]; then
    xcrun notarytool log "$SUBMISSION_ID" "$NOTARY_LOG_PATH" \
      --key "$NOTARY_KEY_PATH" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" \
      --team-id "$TEAM_ID" >/dev/null 2>&1 || true
    printf 'notarization log: %s\n' "$NOTARY_LOG_PATH" >&2
  fi
  fail "Apple returned notarization status ${STATUS:-unknown}"
fi

printf 'stapling notarization ticket\n'
xcrun stapler staple "$PACKAGE_PATH"
xcrun stapler validate "$PACKAGE_PATH"

spctl -a -vvv -t install "$PACKAGE_PATH" >/dev/null

printf 'notarized and stapled package: %s\n' "$PACKAGE_PATH"
