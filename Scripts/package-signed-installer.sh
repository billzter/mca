#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'signed package failed: %s\n' "$1" >&2
  exit 1
}

APP_P12_PATH="${MCA_APP_P12_PATH:-.Secrets/MCADeveloperIDApplicationSigning.p12}"
INSTALLER_P12_PATH="${MCA_INSTALLER_P12_PATH:-.Secrets/MCADeveloperIDInstallerSigning.p12}"
APP_CERT_PATH="${MCA_APP_CERT_PATH:-.Secrets/developerID_application.cer}"
INSTALLER_CERT_PATH="${MCA_INSTALLER_CERT_PATH:-.Secrets/developerID_installer.cer}"
DEVELOPER_ID_INTERMEDIATE_CERT_PATH="${MCA_DEVELOPER_ID_INTERMEDIATE_CERT_PATH:-.Secrets/DeveloperIDG2CA.cer}"
APPLE_ROOT_CERT_PATH="${MCA_APPLE_ROOT_CERT_PATH:-.Secrets/AppleIncRootCertificate.cer}"
APP_P12_PASSWORD="${MCA_APP_P12_PASSWORD:-${MCA_P12_PASSWORD:-}}"
INSTALLER_P12_PASSWORD="${MCA_INSTALLER_P12_PASSWORD:-${MCA_P12_PASSWORD:-}}"
if [ "${MCA_TEMP_KEYCHAIN_PATH:-}" != "" ]; then
  case "$MCA_TEMP_KEYCHAIN_PATH" in
    /*)
      KEYCHAIN_PATH="$MCA_TEMP_KEYCHAIN_PATH"
      ;;
    *)
      KEYCHAIN_PATH="$ROOT_DIR/$MCA_TEMP_KEYCHAIN_PATH"
      ;;
  esac
else
  KEYCHAIN_PATH="$ROOT_DIR/Build/Signing/MCARelease-$(uuidgen).keychain-db"
fi
KEYCHAIN_PASSWORD="${MCA_TEMP_KEYCHAIN_PASSWORD:-$(uuidgen)}"
ORIGINAL_KEYCHAINS_PATH="$(mktemp "${TMPDIR:-/tmp}/mca-keychains.XXXXXX")"
FILTERED_KEYCHAINS_PATH="$(mktemp "${TMPDIR:-/tmp}/mca-keychains-filtered.XXXXXX")"
ORIGINAL_DEFAULT_KEYCHAIN_PATH="$(mktemp "${TMPDIR:-/tmp}/mca-default-keychain.XXXXXX")"
KEYCHAIN_LIST_CHANGED=0
DEFAULT_KEYCHAIN_CHANGED=0

test "$APP_P12_PASSWORD" != "" || fail "set MCA_APP_P12_PASSWORD or MCA_P12_PASSWORD"
test "$INSTALLER_P12_PASSWORD" != "" || fail "set MCA_INSTALLER_P12_PASSWORD or MCA_P12_PASSWORD"
test -f "$APP_P12_PATH" || fail "missing Developer ID Application p12: $APP_P12_PATH"
test -f "$INSTALLER_P12_PATH" || fail "missing Developer ID Installer p12: $INSTALLER_P12_PATH"
test -f "$APP_CERT_PATH" || fail "missing Developer ID Application cert: $APP_CERT_PATH"
test -f "$INSTALLER_CERT_PATH" || fail "missing Developer ID Installer cert: $INSTALLER_CERT_PATH"

cleanup() {
  if [ "$DEFAULT_KEYCHAIN_CHANGED" = "1" ] && [ -s "$ORIGINAL_DEFAULT_KEYCHAIN_PATH" ]; then
    security default-keychain -d user -s "$(cat "$ORIGINAL_DEFAULT_KEYCHAIN_PATH")" >/dev/null 2>&1 || true
  fi
  if [ "$KEYCHAIN_LIST_CHANGED" = "1" ] && [ -f "$ORIGINAL_KEYCHAINS_PATH" ]; then
    # shellcheck disable=SC2046
    security list-keychains -d user -s $(cat "$ORIGINAL_KEYCHAINS_PATH") >/dev/null 2>&1 || true
  fi
  rm -f "$ORIGINAL_KEYCHAINS_PATH" "$FILTERED_KEYCHAINS_PATH" "$ORIGINAL_DEFAULT_KEYCHAIN_PATH"
  if [ "${MCA_KEEP_TEMP_KEYCHAIN:-0}" != "1" ] && [ -f "$KEYCHAIN_PATH" ]; then
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || rm -f "$KEYCHAIN_PATH"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$(dirname "$KEYCHAIN_PATH")"
if [ -f "$KEYCHAIN_PATH" ]; then
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || rm -f "$KEYCHAIN_PATH"
fi

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH" >/dev/null
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//' >"$ORIGINAL_KEYCHAINS_PATH"
grep -vxF "$KEYCHAIN_PATH" "$ORIGINAL_KEYCHAINS_PATH" >"$FILTERED_KEYCHAINS_PATH" || true
security default-keychain -d user | sed 's/^[[:space:]]*"//; s/"$//' >"$ORIGINAL_DEFAULT_KEYCHAIN_PATH"
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN_PATH" $(cat "$FILTERED_KEYCHAINS_PATH") >/dev/null
KEYCHAIN_LIST_CHANGED=1
security default-keychain -d user -s "$KEYCHAIN_PATH" >/dev/null
DEFAULT_KEYCHAIN_CHANGED=1

security import "$APP_P12_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "$APP_P12_PASSWORD" \
  -A \
  -T /usr/bin/codesign \
  -T /usr/bin/pkgbuild \
  -T /usr/bin/productbuild >/dev/null
security import "$APP_CERT_PATH" -k "$KEYCHAIN_PATH" >/dev/null

security import "$INSTALLER_P12_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "$INSTALLER_P12_PASSWORD" \
  -A \
  -T /usr/bin/codesign \
  -T /usr/bin/pkgbuild \
  -T /usr/bin/productbuild >/dev/null
security import "$INSTALLER_CERT_PATH" -k "$KEYCHAIN_PATH" >/dev/null

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH" >/dev/null

APP_SIGN_IDENTITY="$(
  security find-identity -v -p codesigning "$KEYCHAIN_PATH" |
    sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' |
    head -n 1
)"
INSTALLER_SIGN_IDENTITY="$(
  security find-identity -v "$KEYCHAIN_PATH" |
    sed -n 's/.*"\(Developer ID Installer:.*\)".*/\1/p' |
    head -n 1
)"

if [ "$APP_SIGN_IDENTITY" = "" ] || [ "$INSTALLER_SIGN_IDENTITY" = "" ]; then
  printf 'temporary keychain identities found:\n' >&2
  security find-identity "$KEYCHAIN_PATH" >&2 || true
  if [ ! -f "$DEVELOPER_ID_INTERMEDIATE_CERT_PATH" ]; then
    printf 'missing Developer ID G2 intermediate certificate: %s\n' "$DEVELOPER_ID_INTERMEDIATE_CERT_PATH" >&2
    printf 'download it from: https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer\n' >&2
  fi
  if [ ! -f "$APPLE_ROOT_CERT_PATH" ]; then
    printf 'missing Apple Inc. Root certificate: %s\n' "$APPLE_ROOT_CERT_PATH" >&2
    printf 'download it from: https://www.apple.com/appleca/AppleIncRootCertificate.cer\n' >&2
  fi
  test "$APP_SIGN_IDENTITY" != "" || fail "Developer ID Application identity not found in temporary keychain; check that the application .p12 private key matches the application .cer certificate"
  test "$INSTALLER_SIGN_IDENTITY" != "" || fail "Developer ID Installer identity not found in temporary keychain; check that the installer .p12 private key matches the installer .cer certificate"
fi

printf 'using app signing identity: %s\n' "$APP_SIGN_IDENTITY"
printf 'using installer signing identity: %s\n' "$INSTALLER_SIGN_IDENTITY"

if [ "${MCA_SIGNING_SETUP_ONLY:-0}" = "1" ]; then
  printf 'signing setup complete; temporary keychain retained at: %s\n' "$KEYCHAIN_PATH"
  trap - EXIT INT TERM
  rm -f "$ORIGINAL_KEYCHAINS_PATH" "$FILTERED_KEYCHAINS_PATH" "$ORIGINAL_DEFAULT_KEYCHAIN_PATH"
  exit 0
fi

CONFIGURATION="${CONFIGURATION:-Release}" \
APP_SIGN_IDENTITY="$APP_SIGN_IDENTITY" \
DRIVER_SIGN_IDENTITY="${DRIVER_SIGN_IDENTITY:-$APP_SIGN_IDENTITY}" \
INSTALLER_SIGN_IDENTITY="$INSTALLER_SIGN_IDENTITY" \
Scripts/package-installer.sh
