#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'package failed: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  Scripts/build-package.sh [--sign] [--notarize]

Environment:
  MCA_VERSION and MCA_BUILD_NUMBER stamp app/HAL bundle metadata.
  CONFIGURATION defaults to Release.

Signing inputs for --sign / --notarize:
  MCA_APP_P12_PASSWORD and MCA_INSTALLER_P12_PASSWORD, or shared MCA_P12_PASSWORD.
  Optional MCA_APP_P12_PATH, MCA_INSTALLER_P12_PATH, MCA_APP_CERT_PATH,
  MCA_INSTALLER_CERT_PATH override .Secrets defaults.

Notarization inputs for --notarize:
  MCA_NOTARY_KEY_PATH, MCA_NOTARY_KEY_ID, MCA_NOTARY_ISSUER_ID, MCA_TEAM_ID.
EOF
}

SIGN_PACKAGE=0
NOTARIZE_PACKAGE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sign)
      SIGN_PACKAGE=1
      shift
      ;;
    --notarize)
      SIGN_PACKAGE=1
      NOTARIZE_PACKAGE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

CONFIGURATION="${CONFIGURATION:-Release}"
APP_DIR="Build/$CONFIGURATION/MixedCaptureAudio.app"
DRIVER_DIR="Build/$CONFIGURATION/MixedCaptureAudio.driver"
XCODE_DERIVED_DATA="${XCODE_DERIVED_DATA:-Build/XcodeDerivedData}"
if [ "${XCODE_DESTINATION+x}" != "x" ]; then
  if [ "$CONFIGURATION" = "Release" ]; then
    XCODE_DESTINATION="generic/platform=macOS"
  else
    XCODE_DESTINATION="platform=macOS,arch=$(uname -m)"
  fi
fi
XCODE_APP_DIR="$XCODE_DERIVED_DATA/Build/Products/$CONFIGURATION/MixedCaptureAudio.app"
XCODE_DRIVER_DIR="$XCODE_DERIVED_DATA/Build/Products/$CONFIGURATION/MixedCaptureAudio.driver"
PACKAGE_DIR="Build/Packages"
STAGING_ROOT="Build/PackageRoot"
COMPONENT_PLIST="Packaging/MixedCaptureAudioComponentProperties.plist"
PACKAGE_WORK_DIR="Build/PackageWork"
PAYLOAD_VERIFY_ROOT="Build/PackageVerify"
SIGNING_DIR="Build/Signing"

APP_P12_PATH="${MCA_APP_P12_PATH:-.Secrets/MCADeveloperIDApplicationSigning.p12}"
INSTALLER_P12_PATH="${MCA_INSTALLER_P12_PATH:-.Secrets/MCADeveloperIDInstallerSigning.p12}"
APP_CERT_PATH="${MCA_APP_CERT_PATH:-.Secrets/developerID_application.cer}"
INSTALLER_CERT_PATH="${MCA_INSTALLER_CERT_PATH:-.Secrets/developerID_installer.cer}"
DEVELOPER_ID_INTERMEDIATE_CERT_PATH="${MCA_DEVELOPER_ID_INTERMEDIATE_CERT_PATH:-.Secrets/DeveloperIDG2CA.cer}"
APPLE_ROOT_CERT_PATH="${MCA_APPLE_ROOT_CERT_PATH:-.Secrets/AppleIncRootCertificate.cer}"
APP_P12_PASSWORD="${MCA_APP_P12_PASSWORD:-${MCA_P12_PASSWORD:-}}"
INSTALLER_P12_PASSWORD="${MCA_INSTALLER_P12_PASSWORD:-${MCA_P12_PASSWORD:-}}"
KEYCHAIN_PATH=""
KEYCHAIN_PASSWORD=""
ORIGINAL_KEYCHAINS_PATH=""
FILTERED_KEYCHAINS_PATH=""
ORIGINAL_DEFAULT_KEYCHAIN_PATH=""
KEYCHAIN_LIST_CHANGED=0
DEFAULT_KEYCHAIN_CHANGED=0

export COPYFILE_DISABLE=1

cleanup() {
  if [ "$DEFAULT_KEYCHAIN_CHANGED" = "1" ] && [ -s "$ORIGINAL_DEFAULT_KEYCHAIN_PATH" ]; then
    security default-keychain -d user -s "$(cat "$ORIGINAL_DEFAULT_KEYCHAIN_PATH")" >/dev/null 2>&1 || true
  fi
  if [ "$KEYCHAIN_LIST_CHANGED" = "1" ] && [ -f "$ORIGINAL_KEYCHAINS_PATH" ]; then
    # shellcheck disable=SC2046
    security list-keychains -d user -s $(cat "$ORIGINAL_KEYCHAINS_PATH") >/dev/null 2>&1 || true
  fi
  rm -f "$ORIGINAL_KEYCHAINS_PATH" "$FILTERED_KEYCHAINS_PATH" "$ORIGINAL_DEFAULT_KEYCHAIN_PATH"
  if [ "${MCA_KEEP_TEMP_KEYCHAIN:-0}" != "1" ] && [ "$KEYCHAIN_PATH" != "" ] && [ -f "$KEYCHAIN_PATH" ]; then
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || rm -f "$KEYCHAIN_PATH"
  fi
}
trap cleanup EXIT INT TERM

setup_signing() {
  test "$APP_P12_PASSWORD" != "" || fail "set MCA_APP_P12_PASSWORD or MCA_P12_PASSWORD"
  test "$INSTALLER_P12_PASSWORD" != "" || fail "set MCA_INSTALLER_P12_PASSWORD or MCA_P12_PASSWORD"
  test -f "$APP_P12_PATH" || fail "missing Developer ID Application p12: $APP_P12_PATH"
  test -f "$INSTALLER_P12_PATH" || fail "missing Developer ID Installer p12: $INSTALLER_P12_PATH"
  test -f "$APP_CERT_PATH" || fail "missing Developer ID Application cert: $APP_CERT_PATH"
  test -f "$INSTALLER_CERT_PATH" || fail "missing Developer ID Installer cert: $INSTALLER_CERT_PATH"

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
    KEYCHAIN_PATH="$ROOT_DIR/$SIGNING_DIR/MCARelease-$(uuidgen).keychain-db"
  fi
  KEYCHAIN_PASSWORD="${MCA_TEMP_KEYCHAIN_PASSWORD:-$(uuidgen)}"
  ORIGINAL_KEYCHAINS_PATH="$(mktemp "${TMPDIR:-/tmp}/mca-keychains.XXXXXX")"
  FILTERED_KEYCHAINS_PATH="$(mktemp "${TMPDIR:-/tmp}/mca-keychains-filtered.XXXXXX")"
  ORIGINAL_DEFAULT_KEYCHAIN_PATH="$(mktemp "${TMPDIR:-/tmp}/mca-default-keychain.XXXXXX")"

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
    -T /usr/bin/codesign \
    -T /usr/bin/pkgbuild \
    -T /usr/bin/productbuild >/dev/null
  security import "$APP_CERT_PATH" -k "$KEYCHAIN_PATH" >/dev/null

  security import "$INSTALLER_P12_PATH" \
    -k "$KEYCHAIN_PATH" \
    -P "$INSTALLER_P12_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/pkgbuild \
    -T /usr/bin/productbuild \
    -T /usr/bin/productsign >/dev/null
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

  export APP_SIGN_IDENTITY
  export DRIVER_SIGN_IDENTITY="${DRIVER_SIGN_IDENTITY:-$APP_SIGN_IDENTITY}"
  export INSTALLER_SIGN_IDENTITY
  export INSTALLER_SIGN_KEYCHAIN="$KEYCHAIN_PATH"

  printf 'using app signing identity: %s\n' "$APP_SIGN_IDENTITY"
  printf 'using installer signing identity: %s\n' "$INSTALLER_SIGN_IDENTITY"
}

notarize_package() {
  NOTARY_KEY_PATH="${MCA_NOTARY_KEY_PATH:-}"
  NOTARY_KEY_ID="${MCA_NOTARY_KEY_ID:-}"
  NOTARY_ISSUER_ID="${MCA_NOTARY_ISSUER_ID:-}"
  TEAM_ID="${MCA_TEAM_ID:-}"
  LOG_DIR="${MCA_NOTARY_LOG_DIR:-Build/Notarization}"
  SUBMIT_OUTPUT_PLIST="$LOG_DIR/notary-submit.plist"
  NOTARY_LOG_PATH="$LOG_DIR/notary-log.json"

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
}

assert_distribution_entitlements() {
  executable_path="$1"

  if codesign -d --entitlements - "$executable_path" 2>&1 |
    grep -A 3 'com.apple.security.get-task-allow' |
    grep -q '\[Bool\] true'; then
    fail "signed app requests com.apple.security.get-task-allow; Release distribution builds must disable debug base entitlements"
  fi
}

assert_arch_slices() {
  binary_path="$1"
  label="$2"

  test -e "$binary_path" || fail "$label not found: $binary_path"
  arch_info="$(lipo -info "$binary_path" 2>/dev/null)" ||
    fail "could not read architectures for $label: $binary_path"

  for required_arch in arm64 x86_64; do
    case " $arch_info " in
      *" $required_arch "*)
        ;;
      *)
        fail "$label missing required $required_arch slice: $arch_info"
        ;;
    esac
  done

  printf 'verified %s architectures: %s\n' "$label" "$arch_info"
}

assert_release_build_architectures() {
  if [ "$CONFIGURATION" != "Release" ]; then
    return
  fi

  assert_arch_slices "$APP_DIR/Contents/MacOS/MixedCaptureAudio" "app executable"
  assert_arch_slices "$DRIVER_DIR/Contents/MacOS/MixedCaptureAudio" "HAL driver executable"
  assert_arch_slices "$ROOT_DIR/Generated/lib/release/libmixed_audio_engine.a" "Rust static library"
}

assert_release_payload_architectures() {
  if [ "$CONFIGURATION" != "Release" ]; then
    return
  fi

  assert_arch_slices "$PAYLOAD_VERIFY_ROOT/Payload/Applications/MixedCaptureAudio.app/Contents/MacOS/MixedCaptureAudio" "packaged app executable"
  assert_arch_slices "$PAYLOAD_VERIFY_ROOT/Payload/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver/Contents/MacOS/MixedCaptureAudio" "packaged HAL driver executable"
}

run_xcodebuild_build() {
  scheme="$1"
  marketing_version="$2"
  current_project_version="$3"
  code_sign_identity="$4"
  other_code_sign_flags="$5"

  set -- build \
    -project MixedCaptureAudio.xcodeproj \
    -scheme "$scheme"

  if [ "$XCODE_DESTINATION" != "" ]; then
    set -- "$@" -destination "$XCODE_DESTINATION"
  fi

  set -- "$@" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$XCODE_DERIVED_DATA" \
    "MARKETING_VERSION=$marketing_version" \
    "CURRENT_PROJECT_VERSION=$current_project_version" \
    "CODE_SIGN_IDENTITY=$code_sign_identity"

  if [ "$other_code_sign_flags" != "" ]; then
    set -- "$@" "OTHER_CODE_SIGN_FLAGS=$other_code_sign_flags"
  fi

  xcodebuild "$@"
}

create_clean_package() {
  unsigned_package_path="$PACKAGE_WORK_DIR/MixedCaptureAudio-unsigned.pkg"
  clean_unsigned_package_path="$PACKAGE_WORK_DIR/MixedCaptureAudio-clean-unsigned.pkg"
  expanded_package_dir="$PACKAGE_WORK_DIR/Expanded"
  bom_list_path="$PACKAGE_WORK_DIR/Bom.list"
  expanded_payload_path="$ROOT_DIR/$expanded_package_dir/Payload"

  rm -rf "$PACKAGE_WORK_DIR" "$PACKAGE_PATH"
  mkdir -p "$PACKAGE_WORK_DIR"

  # Newer macOS/pkgbuild can archive provenance extended attributes as
  # AppleDouble payload records (._Foo and .__CodeSignature), even when the
  # staging tree has no AppleDouble files and xattr/ditto/filter cleanup has
  # already run. Those zero-byte records are harmless after notarization, but
  # they clutter the installer payload and previously caused entitlement
  # debugging confusion.
  #
  # Keep pkgbuild in charge of the PackageInfo/component metadata, then expand
  # that unsigned package and replace only its Bom/Payload:
  # - filter AppleDouble paths out of the generated bill of materials
  # - rebuild the cpio payload from the cleaned staging root
  # - flatten and, for release builds, sign the cleaned package with productsign
  #
  # The final assert_no_appledouble_payload check below keeps this behavior
  # honest if Apple's packaging tools change again.
  # shellcheck disable=SC2086
  pkgbuild $PKGBUILD_ARGS "$unsigned_package_path"

  pkgutil --expand "$unsigned_package_path" "$expanded_package_dir"
  lsbom "$expanded_package_dir/Bom" |
    grep -Ev '(^|/)\._|(^|/)\.__CodeSignature' >"$bom_list_path"
  mkbom -i "$bom_list_path" "$expanded_package_dir/Bom"

  (
    cd "$STAGING_ROOT"
    find . ! -name '._*' ! -name '.DS_Store' -print |
      LC_ALL=C sort |
      cpio -o -H odc -R 0:0 2>/dev/null |
      gzip -c >"$expanded_payload_path"
  )

  pkgutil --flatten "$expanded_package_dir" "$clean_unsigned_package_path" >/dev/null

  if [ "$SIGN_PACKAGE" = "1" ]; then
    productsign \
      --sign "$INSTALLER_SIGN_IDENTITY" \
      --keychain "$INSTALLER_SIGN_KEYCHAIN" \
      "$clean_unsigned_package_path" \
      "$PACKAGE_PATH" >/dev/null
  else
    mv "$clean_unsigned_package_path" "$PACKAGE_PATH"
  fi

  rm -rf "$PACKAGE_WORK_DIR"
}

assert_no_appledouble_payload() {
  if pkgutil --payload-files "$PACKAGE_PATH" | grep -Eq '(^|/)\._|(^|/)\.__CodeSignature'; then
    fail "package payload contains AppleDouble metadata entries"
  fi
}

build_app() {
  marketing_version="${MCA_VERSION:-0.1}"
  current_project_version="${MCA_BUILD_NUMBER:-1}"
  code_sign_identity="${APP_SIGN_IDENTITY:--}"

  if [ "$KEYCHAIN_PATH" != "" ]; then
    run_xcodebuild_build \
      MixedCaptureAudioApp \
      "$marketing_version" \
      "$current_project_version" \
      "$code_sign_identity" \
      "--keychain $KEYCHAIN_PATH --timestamp"
  else
    run_xcodebuild_build \
      MixedCaptureAudioApp \
      "$marketing_version" \
      "$current_project_version" \
      "$code_sign_identity" \
      ""
  fi

  test -d "$XCODE_APP_DIR" || fail "Xcode app product not found: $XCODE_APP_DIR"
  rm -rf "$APP_DIR"
  mkdir -p "$(dirname "$APP_DIR")"
  ditto --norsrc --noextattr "$XCODE_APP_DIR" "$APP_DIR"
  xattr -cr "$APP_DIR" 2>/dev/null || true
}

build_driver() {
  marketing_version="${MCA_VERSION:-0.1}"
  current_project_version="${MCA_BUILD_NUMBER:-1}"
  code_sign_identity="${DRIVER_SIGN_IDENTITY:-${APP_SIGN_IDENTITY:--}}"

  if [ "$KEYCHAIN_PATH" != "" ]; then
    run_xcodebuild_build \
      MixedCaptureAudioDriver \
      "$marketing_version" \
      "$current_project_version" \
      "$code_sign_identity" \
      "--keychain $KEYCHAIN_PATH --timestamp"
  else
    run_xcodebuild_build \
      MixedCaptureAudioDriver \
      "$marketing_version" \
      "$current_project_version" \
      "$code_sign_identity" \
      ""
  fi

  test -d "$XCODE_DRIVER_DIR" || fail "Xcode HAL driver product not found: $XCODE_DRIVER_DIR"
  rm -rf "$DRIVER_DIR"
  mkdir -p "$(dirname "$DRIVER_DIR")"
  ditto --norsrc --noextattr "$XCODE_DRIVER_DIR" "$DRIVER_DIR"
  xattr -cr "$DRIVER_DIR" 2>/dev/null || true
}

if [ "$SIGN_PACKAGE" = "1" ]; then
  setup_signing
fi

build_app
build_driver
codesign --verify --deep --strict --verbose=4 "$APP_DIR" >/dev/null
codesign --verify --deep --strict --verbose=4 "$DRIVER_DIR" >/dev/null
assert_release_build_architectures
if [ "$SIGN_PACKAGE" = "1" ]; then
  assert_distribution_entitlements "$APP_DIR/Contents/MacOS/MixedCaptureAudio"
fi

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_DIR/Contents/Info.plist")"
PACKAGE_PATH="$PACKAGE_DIR/MixedCaptureAudio-$APP_VERSION.pkg"

rm -rf "$STAGING_ROOT"
mkdir -p "$STAGING_ROOT/Applications" "$STAGING_ROOT/Library/Audio/Plug-Ins/HAL" "$PACKAGE_DIR"

ditto --norsrc --noextattr "$APP_DIR" "$STAGING_ROOT/Applications/MixedCaptureAudio.app"
ditto --norsrc --noextattr "$DRIVER_DIR" "$STAGING_ROOT/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver"
xattr -cr "$STAGING_ROOT" 2>/dev/null || true
find "$STAGING_ROOT" \( -name '._*' -o -name '.DS_Store' \) -exec rm -f {} +

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

create_clean_package

pkgutil --check-signature "$PACKAGE_PATH" >/dev/null 2>&1 || {
  if [ "$SIGN_PACKAGE" = "1" ]; then
    printf 'package signature verification failed: %s\n' "$PACKAGE_PATH" >&2
    exit 1
  fi
}
assert_no_appledouble_payload

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
assert_release_payload_architectures
rm -rf "$PAYLOAD_VERIFY_ROOT"

printf 'built %s\n' "$PACKAGE_PATH"

if [ "$NOTARIZE_PACKAGE" = "1" ]; then
  notarize_package
else
  printf 'Installer updates app and HAL driver only. Restart the Mac if MCA reports Restart required after installation.\n'
fi
