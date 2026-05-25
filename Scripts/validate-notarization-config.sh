#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'notarization config validation failed: %s\n' "$1" >&2
  exit 1
}

sh -n Scripts/notarize-package.sh Scripts/mca-build

MISSING_ENV_PACKAGE="$(mktemp "${TMPDIR:-/tmp}/mca-notary-missing-env-package.XXXXXX.pkg")"
trap 'rm -f "$MISSING_ENV_PACKAGE"' EXIT INT TERM

unset MCA_NOTARY_KEY_PATH
unset MCA_NOTARY_KEY_ID
unset MCA_NOTARY_ISSUER_ID
unset MCA_TEAM_ID
if MCA_NOTARY_PACKAGE_PATH="$MISSING_ENV_PACKAGE" Scripts/notarize-package.sh >/tmp/mca-notarization-missing-env.log 2>&1; then
  fail "notarization script succeeded without credentials"
fi
grep -q 'missing App Store Connect API key file' /tmp/mca-notarization-missing-env.log ||
  fail "notarization script did not fail with expected key path guidance"

printf 'notarization config validation passed\n'
