#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage: Scripts/release-support.sh <command> [args]

Commands:
  decode-secrets                    Decode base64 release secret files into .Secrets.
  install-public-certs              Import public Apple signing certificates into a keychain.
  resolve-tag                       Resolve and validate the GitHub release tag.
USAGE
}

fail() {
  printf '%s failed: %s\n' "$1" "$2" >&2
  exit 1
}

decode_file() {
  value="$1"
  output_path="$2"
  description="$3"

  test "$value" != "" || fail "release secret decode" "missing $description"
  printf '%s' "$value" | base64 --decode > "$output_path"
  chmod 600 "$output_path"
}

decode_secrets() {
  secrets_dir="${MCA_SECRETS_DIR:-.Secrets}"

  umask 077
  install -d -m 700 "$secrets_dir"

  decode_file "${MCA_APP_P12_BASE64:-}" \
    "$secrets_dir/MCADeveloperIDApplicationSigning.p12" \
    "Developer ID Application p12"
  decode_file "${MCA_INSTALLER_P12_BASE64:-}" \
    "$secrets_dir/MCADeveloperIDInstallerSigning.p12" \
    "Developer ID Installer p12"
  decode_file "${MCA_APP_CERT_BASE64:-}" \
    "$secrets_dir/developerID_application.cer" \
    "Developer ID Application public certificate"
  decode_file "${MCA_INSTALLER_CERT_BASE64:-}" \
    "$secrets_dir/developerID_installer.cer" \
    "Developer ID Installer public certificate"
  decode_file "${MCA_NOTARY_KEY_BASE64:-}" \
    "$secrets_dir/notary-key.p8" \
    "App Store Connect API key"
}

import_public_cert() {
  cert_path="$1"
  description="$2"

  if ! import_output="$(security import "$cert_path" -k "$LOGIN_KEYCHAIN" 2>&1)"; then
    case "$import_output" in
      *"The specified item already exists in the keychain."*)
        ;;
      *)
        printf 'could not import %s:\n%s\n' "$description" "$import_output" >&2
        return 1
        ;;
    esac
  fi
}

verify_public_cert() {
  cert_path="$1"
  policy="$2"
  description="$3"

  verify_output="$(security verify-cert -c "$cert_path" -p "$policy" 2>&1)" && return 0
  case "$verify_output" in
    *"policy creation failed"*)
      printf '%s\n' "$verify_output" >&2
      return 1
      ;;
    *"Cert Verify Result: No error."*)
      return 0
      ;;
    *)
      printf 'could not verify %s:\n%s\n' "$description" "$verify_output" >&2
      return 1
      ;;
  esac
}

install_public_certs() {
  LOGIN_KEYCHAIN="${MCA_PUBLIC_CERT_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
  app_cert_path="${MCA_APP_CERT_PATH:-.Secrets/developerID_application.cer}"
  installer_cert_path="${MCA_INSTALLER_CERT_PATH:-.Secrets/developerID_installer.cer}"
  developer_id_intermediate_cert_path="${MCA_DEVELOPER_ID_INTERMEDIATE_CERT_PATH:-.Secrets/DeveloperIDG2CA.cer}"
  apple_root_cert_path="${MCA_APPLE_ROOT_CERT_PATH:-.Secrets/AppleIncRootCertificate.cer}"

  test -f "$app_cert_path" || fail "public signing cert install" "missing Developer ID Application cert: $app_cert_path"
  test -f "$installer_cert_path" || fail "public signing cert install" "missing Developer ID Installer cert: $installer_cert_path"
  test -f "$developer_id_intermediate_cert_path" || fail "public signing cert install" "missing Developer ID G2 intermediate cert: $developer_id_intermediate_cert_path"

  printf 'Installing public Apple signing certificates into %s\n' "$LOGIN_KEYCHAIN"
  printf 'This does not import private keys or .p12 files.\n'

  import_public_cert "$app_cert_path" "Developer ID Application public certificate"
  import_public_cert "$installer_cert_path" "Developer ID Installer public certificate"
  import_public_cert "$developer_id_intermediate_cert_path" "Developer ID G2 intermediate certificate"

  if [ -f "$apple_root_cert_path" ]; then
    import_public_cert "$apple_root_cert_path" "Apple Root CA certificate"
  fi

  if [ "${MCA_SKIP_PUBLIC_CERT_VERIFY:-0}" != "1" ]; then
    if ! verify_public_cert "$app_cert_path" codeSign "Developer ID Application certificate"; then
      fail "public signing cert install" "Developer ID Application certificate still does not verify through the normal keychain search list"
    fi
    if ! verify_public_cert "$installer_cert_path" pkgSign "Developer ID Installer certificate"; then
      fail "public signing cert install" "Developer ID Installer certificate still does not verify through the normal keychain search list"
    fi
  fi

  printf 'public Apple signing certificate chain is available to codesign\n'
}

resolve_tag() {
  if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
    release_tag="${GITHUB_REF_NAME:-}"
  else
    release_tag="${INPUT_RELEASE_TAG:-}"
  fi

  test "$release_tag" != "" || fail "release tag resolution" "missing release tag"

  case "$release_tag" in
    v[0-9]*)
      ;;
    *)
      fail "release tag resolution" "invalid release tag: expected v-prefixed version tag"
      ;;
  esac

  case "$release_tag" in
    *[!A-Za-z0-9._-]*)
      fail "release tag resolution" "invalid release tag: only letters, numbers, dots, underscores, and hyphens are allowed"
      ;;
  esac

  if [ "${GITHUB_OUTPUT:-}" != "" ]; then
    printf 'release_tag=%s\n' "$release_tag" >> "$GITHUB_OUTPUT"
  else
    printf 'release_tag=%s\n' "$release_tag"
  fi
}

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 2
fi

command="$1"
shift

case "$command" in
  decode-secrets)
    decode_secrets
    ;;
  install-public-certs)
    install_public_certs
    ;;
  resolve-tag)
    resolve_tag
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
