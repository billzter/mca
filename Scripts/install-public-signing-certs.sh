#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'public signing cert install failed: %s\n' "$1" >&2
  exit 1
}

import_public_cert() {
  CERT_PATH="$1"
  DESCRIPTION="$2"

  if ! IMPORT_OUTPUT="$(security import "$CERT_PATH" -k "$LOGIN_KEYCHAIN" 2>&1)"; then
    case "$IMPORT_OUTPUT" in
      *"The specified item already exists in the keychain."*)
        ;;
      *)
        printf 'could not import %s:\n%s\n' "$DESCRIPTION" "$IMPORT_OUTPUT" >&2
        return 1
        ;;
    esac
  fi
}

verify_public_cert() {
  CERT_PATH="$1"
  POLICY="$2"
  DESCRIPTION="$3"

  VERIFY_OUTPUT="$(security verify-cert -c "$CERT_PATH" -p "$POLICY" 2>&1)" && return 0
  case "$VERIFY_OUTPUT" in
    *"policy creation failed"*)
      printf '%s\n' "$VERIFY_OUTPUT" >&2
      return 1
      ;;
    *"Cert Verify Result: No error."*)
      return 0
      ;;
    *)
      printf 'could not verify %s:\n%s\n' "$DESCRIPTION" "$VERIFY_OUTPUT" >&2
      return 1
      ;;
  esac
}

LOGIN_KEYCHAIN="${MCA_PUBLIC_CERT_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
APP_CERT_PATH="${MCA_APP_CERT_PATH:-.Secrets/developerID_application.cer}"
INSTALLER_CERT_PATH="${MCA_INSTALLER_CERT_PATH:-.Secrets/developerID_installer.cer}"
DEVELOPER_ID_INTERMEDIATE_CERT_PATH="${MCA_DEVELOPER_ID_INTERMEDIATE_CERT_PATH:-.Secrets/DeveloperIDG2CA.cer}"
APPLE_ROOT_CERT_PATH="${MCA_APPLE_ROOT_CERT_PATH:-.Secrets/AppleIncRootCertificate.cer}"

test -f "$APP_CERT_PATH" || fail "missing Developer ID Application cert: $APP_CERT_PATH"
test -f "$INSTALLER_CERT_PATH" || fail "missing Developer ID Installer cert: $INSTALLER_CERT_PATH"
test -f "$DEVELOPER_ID_INTERMEDIATE_CERT_PATH" || fail "missing Developer ID G2 intermediate cert: $DEVELOPER_ID_INTERMEDIATE_CERT_PATH"

printf 'Installing public Apple signing certificates into %s\n' "$LOGIN_KEYCHAIN"
printf 'This does not import private keys or .p12 files.\n'

import_public_cert "$APP_CERT_PATH" "Developer ID Application public certificate"
import_public_cert "$INSTALLER_CERT_PATH" "Developer ID Installer public certificate"
import_public_cert "$DEVELOPER_ID_INTERMEDIATE_CERT_PATH" "Developer ID G2 intermediate certificate"

if [ -f "$APPLE_ROOT_CERT_PATH" ]; then
  import_public_cert "$APPLE_ROOT_CERT_PATH" "Apple Root CA certificate"
fi

if [ "${MCA_SKIP_PUBLIC_CERT_VERIFY:-0}" != "1" ]; then
  if ! verify_public_cert "$APP_CERT_PATH" codeSign "Developer ID Application certificate"; then
    fail "Developer ID Application certificate still does not verify through the normal keychain search list"
  fi
  if ! verify_public_cert "$INSTALLER_CERT_PATH" pkgSign "Developer ID Installer certificate"; then
    fail "Developer ID Installer certificate still does not verify through the normal keychain search list"
  fi
fi

printf 'public Apple signing certificate chain is available to codesign\n'
