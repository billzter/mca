#!/bin/sh
set -eu

fail() {
  printf 'release tag resolution failed: %s\n' "$1" >&2
  exit 1
}

if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
  RELEASE_TAG="${GITHUB_REF_NAME:-}"
else
  RELEASE_TAG="${INPUT_RELEASE_TAG:-}"
fi

test "$RELEASE_TAG" != "" || fail "missing release tag"

case "$RELEASE_TAG" in
  v[0-9]*)
    ;;
  *)
    fail "invalid release tag: expected v-prefixed version tag"
    ;;
esac

case "$RELEASE_TAG" in
  *[!A-Za-z0-9._-]*)
    fail "invalid release tag: only letters, numbers, dots, underscores, and hyphens are allowed"
    ;;
esac

if [ "${GITHUB_OUTPUT:-}" != "" ]; then
  printf 'release_tag=%s\n' "$RELEASE_TAG" >> "$GITHUB_OUTPUT"
else
  printf 'release_tag=%s\n' "$RELEASE_TAG"
fi
