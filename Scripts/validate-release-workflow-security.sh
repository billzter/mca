#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'release workflow security validation failed: %s\n' "$1" >&2
  exit 1
}

sh -n Scripts/decode-release-secret-files.sh \
  Scripts/resolve-release-tag.sh

ruby <<'RUBY'
require "yaml"

workflow = YAML.load_file(".github/workflows/release.yml")
jobs = workflow.fetch("jobs")
package = jobs.fetch("package")

abort "release workflow should use one macOS package job" unless jobs.keys == ["package"]
abort "package job must stay on macos-14" unless package["runs-on"] == "macos-14"
abort "package job needs contents write for direct gh release upload" unless package.dig("permissions", "contents") == "write"

checkout = package.fetch("steps").find { |step| step["uses"].to_s.start_with?("actions/checkout@") }
abort "checkout step is missing" unless checkout
abort "checkout must disable persisted credentials" unless checkout.dig("with", "persist-credentials") == false

all_steps = package.fetch("steps")
abort "release workflow must not use artifact upload/download actions" if all_steps.any? { |step| step["uses"].to_s.include?("upload-artifact") || step["uses"].to_s.include?("download-artifact") }
abort "release workflow must upload the package directly with gh" unless all_steps.any? { |step| step.fetch("run", "").include?("gh release upload") }
RUBY

SECRETS_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mca-release-secrets.XXXXXX")"
trap 'rm -rf "$SECRETS_TEST_ROOT"' EXIT INT TERM

DUMMY_VALUE="$(printf 'dummy' | base64)"
MCA_SECRETS_DIR="$SECRETS_TEST_ROOT/.Secrets" \
  MCA_APP_P12_BASE64="$DUMMY_VALUE" \
  MCA_INSTALLER_P12_BASE64="$DUMMY_VALUE" \
  MCA_APP_CERT_BASE64="$DUMMY_VALUE" \
  MCA_INSTALLER_CERT_BASE64="$DUMMY_VALUE" \
  MCA_NOTARY_KEY_BASE64="$DUMMY_VALUE" \
  Scripts/decode-release-secret-files.sh

DIR_MODE="$(stat -f '%Lp' "$SECRETS_TEST_ROOT/.Secrets")"
test "$DIR_MODE" = "700" ||
  fail "decoded secrets directory mode was $DIR_MODE"

for path in \
  "$SECRETS_TEST_ROOT/.Secrets/MCADeveloperIDApplicationSigning.p12" \
  "$SECRETS_TEST_ROOT/.Secrets/MCADeveloperIDInstallerSigning.p12" \
  "$SECRETS_TEST_ROOT/.Secrets/developerID_application.cer" \
  "$SECRETS_TEST_ROOT/.Secrets/developerID_installer.cer" \
  "$SECRETS_TEST_ROOT/.Secrets/notary-key.p8"
do
  FILE_MODE="$(stat -f '%Lp' "$path")"
  test "$FILE_MODE" = "600" ||
    fail "decoded secret file mode was $FILE_MODE for $path"
done

printf 'release workflow security validation passed\n'
