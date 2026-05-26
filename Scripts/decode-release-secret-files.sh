#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'release secret decode failed: %s\n' "$1" >&2
  exit 1
}

SECRETS_DIR="${MCA_SECRETS_DIR:-.Secrets}"

decode_file() {
  VALUE="$1"
  OUTPUT_PATH="$2"
  DESCRIPTION="$3"

  test "$VALUE" != "" || fail "missing $DESCRIPTION"
  printf '%s' "$VALUE" | base64 --decode > "$OUTPUT_PATH"
  chmod 600 "$OUTPUT_PATH"
}

umask 077
install -d -m 700 "$SECRETS_DIR"

decode_file "${MCA_APP_P12_BASE64:-}" \
  "$SECRETS_DIR/MCADeveloperIDApplicationSigning.p12" \
  "Developer ID Application p12"
decode_file "${MCA_INSTALLER_P12_BASE64:-}" \
  "$SECRETS_DIR/MCADeveloperIDInstallerSigning.p12" \
  "Developer ID Installer p12"
decode_file "${MCA_APP_CERT_BASE64:-}" \
  "$SECRETS_DIR/developerID_application.cer" \
  "Developer ID Application public certificate"
decode_file "${MCA_INSTALLER_CERT_BASE64:-}" \
  "$SECRETS_DIR/developerID_installer.cer" \
  "Developer ID Installer public certificate"
decode_file "${MCA_NOTARY_KEY_BASE64:-}" \
  "$SECRETS_DIR/notary-key.p8" \
  "App Store Connect API key"
