#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DIAG_KEYCHAIN="$ROOT_DIR/Build/Signing/MCADiagnostics.keychain-db"
DIAG_PASSWORD="${MCA_TEMP_KEYCHAIN_PASSWORD:-mca-diagnostics-keychain}"
ORIGINAL_KEYCHAINS_PATH="$(mktemp "${TMPDIR:-/tmp}/mca-diagnostic-keychains.XXXXXX")"
ORIGINAL_DEFAULT_KEYCHAIN_PATH="$(mktemp "${TMPDIR:-/tmp}/mca-diagnostic-default-keychain.XXXXXX")"

security list-keychains -d user |
  sed 's/^[[:space:]]*"//; s/"$//' |
  grep -vxF "$DIAG_KEYCHAIN" >"$ORIGINAL_KEYCHAINS_PATH" || true
security default-keychain -d user | sed 's/^[[:space:]]*"//; s/"$//' >"$ORIGINAL_DEFAULT_KEYCHAIN_PATH"

cleanup() {
  if [ -s "$ORIGINAL_DEFAULT_KEYCHAIN_PATH" ]; then
    security default-keychain -d user -s "$(cat "$ORIGINAL_DEFAULT_KEYCHAIN_PATH")" >/dev/null 2>&1 || true
  fi
  if [ -f "$ORIGINAL_KEYCHAINS_PATH" ]; then
    # shellcheck disable=SC2046
    security list-keychains -d user -s $(cat "$ORIGINAL_KEYCHAINS_PATH") >/dev/null 2>&1 || true
  fi
  rm -f "$ORIGINAL_KEYCHAINS_PATH" "$ORIGINAL_DEFAULT_KEYCHAIN_PATH"
}
trap cleanup EXIT INT TERM

printf 'release signing diagnostics\n'
printf 'keychain=%s\n' "$DIAG_KEYCHAIN"

MCA_KEEP_TEMP_KEYCHAIN=1 \
MCA_TEMP_KEYCHAIN_PATH="$DIAG_KEYCHAIN" \
MCA_TEMP_KEYCHAIN_PASSWORD="$DIAG_PASSWORD" \
MCA_SIGNING_SETUP_ONLY=1 \
Scripts/package-signed-installer.sh

printf '\nidentity list:\n'
security find-identity -v "$DIAG_KEYCHAIN" || true

printf '\ncode signing identities:\n'
security find-identity -v -p codesigning "$DIAG_KEYCHAIN" || true

printf '\ncertificate verification with explicit files:\n'
security verify-cert \
  -c "${MCA_APP_CERT_PATH:-.Secrets/developerID_application.cer}" \
  -c "${MCA_DEVELOPER_ID_INTERMEDIATE_CERT_PATH:-.Secrets/DeveloperIDG2CA.cer}" \
  -r "${MCA_APPLE_ROOT_CERT_PATH:-.Secrets/AppleIncRootCertificate.cer}" \
  -p codeSign \
  -L \
  -v || true

printf '\ncertificate verification through current keychain search list:\n'
security verify-cert \
  -c "${MCA_APP_CERT_PATH:-.Secrets/developerID_application.cer}" \
  -p codeSign \
  -L \
  -v || true

printf '\nDeveloper ID CA certificates visible in current keychain search list:\n'
security find-certificate -a -c "Developer ID Certification Authority" -Z || true

printf '\nApple Root CA certificates visible in current keychain search list:\n'
security find-certificate -a -c "Apple Root CA" -Z || true

APP_SIGN_IDENTITY="$(
  security find-identity -v -p codesigning "$DIAG_KEYCHAIN" |
    sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' |
    head -n 1
)"
APP_SIGN_SHA1="$(
  security find-identity -v -p codesigning "$DIAG_KEYCHAIN" |
    sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*\\([0-9A-F][0-9A-F]*\\)[[:space:]].*/\\1/p' |
    head -n 1
)"

if [ "$APP_SIGN_IDENTITY" = "" ]; then
  printf '\nno Developer ID Application identity found; stopping diagnostics\n' >&2
  exit 1
fi

DIAG_DIR="$ROOT_DIR/Build/Signing/Diagnostics"
DIAG_BIN="$DIAG_DIR/hello"
mkdir -p "$DIAG_DIR"
printf '%s\n' 'int main(void) { return 0; }' >"$DIAG_DIR/hello.c"
clang "$DIAG_DIR/hello.c" -o "$DIAG_BIN"

printf '\nthrowaway codesign without timestamp:\n'
codesign \
  --force \
  --verbose=4 \
  --sign "$APP_SIGN_IDENTITY" \
  --timestamp=none \
  "$DIAG_BIN" || true

printf '\nthrowaway codesign without timestamp using explicit keychain:\n'
codesign \
  --force \
  --verbose=4 \
  --sign "$APP_SIGN_IDENTITY" \
  --keychain "$DIAG_KEYCHAIN" \
  --timestamp=none \
  "$DIAG_BIN" || true

if [ "$APP_SIGN_SHA1" != "" ]; then
  printf '\nthrowaway codesign without timestamp using SHA-1 identity:\n'
  codesign \
    --force \
    --verbose=4 \
    --sign "$APP_SIGN_SHA1" \
    --timestamp=none \
    "$DIAG_BIN" || true
fi

printf '\nthrowaway verification without timestamp:\n'
codesign --verify --deep --strict --verbose=4 "$DIAG_BIN" || true

rm -f "$DIAG_DIR"/extracted-cert-*
printf '\ncertificates embedded in throwaway signature:\n'
codesign -d --extract-certificates "$DIAG_DIR/extracted-cert-" "$DIAG_BIN" >/dev/null 2>&1 || true
ls "$DIAG_DIR"/extracted-cert-* 2>/dev/null || true

printf '\nthrowaway codesign with Apple timestamp:\n'
codesign \
  --force \
  --verbose=4 \
  --sign "$APP_SIGN_IDENTITY" \
  --timestamp \
  "$DIAG_BIN" || true

printf '\nthrowaway verification with timestamp:\n'
codesign --verify --deep --strict --verbose=4 "$DIAG_BIN" || true

printf '\ndiagnostics complete. To delete the diagnostic keychain:\n'
printf 'security delete-keychain %s\n' "$DIAG_KEYCHAIN"
