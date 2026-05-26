#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'build orchestration validation failed: %s\n' "$1" >&2
  exit 1
}

sh -n Scripts/mca-build \
  Scripts/build-app.sh \
  Scripts/build-hal-driver.sh \
  Scripts/package-installer.sh \
  Scripts/resolve-release-tag.sh

TEST_VERSION="9.8.7"
TEST_BUILD="987"
TAG_TEST_VERSION="7.6.5"
TAG_TEST_BUILD="765"

SOURCE_APP_VERSION_BEFORE="$(plutil -extract CFBundleShortVersionString raw -o - App/Resources/Info.plist)"
SOURCE_APP_BUILD_BEFORE="$(plutil -extract CFBundleVersion raw -o - App/Resources/Info.plist)"
SOURCE_DRIVER_VERSION_BEFORE="$(plutil -extract CFBundleShortVersionString raw -o - HALPlugin/Resources/Info.plist)"
SOURCE_DRIVER_BUILD_BEFORE="$(plutil -extract CFBundleVersion raw -o - HALPlugin/Resources/Info.plist)"

Scripts/mca-build version --version "$TEST_VERSION" --build "$TEST_BUILD" >/tmp/mca-build-version.txt
grep -q "^MCA_VERSION=$TEST_VERSION$" /tmp/mca-build-version.txt ||
  fail "version command did not report explicit version"
grep -q "^MCA_BUILD_NUMBER=$TEST_BUILD$" /tmp/mca-build-version.txt ||
  fail "version command did not report explicit build number"

GITHUB_REF_TYPE=tag GITHUB_REF_NAME="v$TAG_TEST_VERSION" MCA_BUILD_NUMBER="$TAG_TEST_BUILD" \
  Scripts/mca-build version >/tmp/mca-build-tag-version.txt
grep -q "^MCA_VERSION=$TAG_TEST_VERSION$" /tmp/mca-build-tag-version.txt ||
  fail "version command did not derive version from GitHub tag"

rm -f /tmp/mca-release-tag-from-ref.txt
GITHUB_OUTPUT=/tmp/mca-release-tag-from-ref.txt \
  GITHUB_REF_TYPE=tag \
  GITHUB_REF_NAME="v$TAG_TEST_VERSION" \
  Scripts/resolve-release-tag.sh
grep -q "^release_tag=v$TAG_TEST_VERSION$" /tmp/mca-release-tag-from-ref.txt ||
  fail "release tag resolver did not use GitHub tag refs"

rm -f /tmp/mca-release-tag-from-input.txt
GITHUB_OUTPUT=/tmp/mca-release-tag-from-input.txt \
  GITHUB_REF_TYPE=branch \
  INPUT_RELEASE_TAG="v$TEST_VERSION" \
  Scripts/resolve-release-tag.sh
grep -q "^release_tag=v$TEST_VERSION$" /tmp/mca-release-tag-from-input.txt ||
  fail "release tag resolver did not use manual dispatch input"

if GITHUB_OUTPUT=/tmp/mca-release-tag-missing-output.txt \
  GITHUB_REF_TYPE=branch \
  INPUT_RELEASE_TAG="" \
  Scripts/resolve-release-tag.sh >/tmp/mca-release-tag-missing.txt 2>&1; then
  fail "release tag resolver accepted missing manual dispatch input"
fi
grep -q "missing release tag" /tmp/mca-release-tag-missing.txt ||
  fail "release tag resolver did not report missing manual dispatch input"

if GITHUB_OUTPUT=/tmp/mca-release-tag-injection-output.txt \
  GITHUB_REF_TYPE=branch \
  INPUT_RELEASE_TAG='v1.2.3"; touch /tmp/mca-release-tag-injected #' \
  Scripts/resolve-release-tag.sh >/tmp/mca-release-tag-injection.txt 2>&1; then
  fail "release tag resolver accepted shell metacharacters"
fi
grep -q "invalid release tag" /tmp/mca-release-tag-injection.txt ||
  fail "release tag resolver did not reject shell metacharacters"
test ! -e /tmp/mca-release-tag-injected ||
  fail "release tag resolver allowed shell injection side effect"

Scripts/mca-build package --version "$TEST_VERSION" --build "$TEST_BUILD" >/tmp/mca-orchestrated-package.log

APP_PLIST="Build/Release/MixedCaptureAudio.app/Contents/Info.plist"
DRIVER_PLIST="Build/Release/MixedCaptureAudio.driver/Contents/Info.plist"
PACKAGE_PATH="Build/Packages/MixedCaptureAudio-$TEST_VERSION.pkg"

test -f "$PACKAGE_PATH" || fail "orchestrated package was not created: $PACKAGE_PATH"

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PLIST")"
APP_BUILD="$(plutil -extract CFBundleVersion raw -o - "$APP_PLIST")"
DRIVER_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$DRIVER_PLIST")"
DRIVER_BUILD="$(plutil -extract CFBundleVersion raw -o - "$DRIVER_PLIST")"

test "$APP_VERSION" = "$TEST_VERSION" || fail "app version was $APP_VERSION"
test "$APP_BUILD" = "$TEST_BUILD" || fail "app build was $APP_BUILD"
test "$DRIVER_VERSION" = "$TEST_VERSION" || fail "driver version was $DRIVER_VERSION"
test "$DRIVER_BUILD" = "$TEST_BUILD" || fail "driver build was $DRIVER_BUILD"

SOURCE_APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - App/Resources/Info.plist)"
SOURCE_APP_BUILD="$(plutil -extract CFBundleVersion raw -o - App/Resources/Info.plist)"
SOURCE_DRIVER_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - HALPlugin/Resources/Info.plist)"
SOURCE_DRIVER_BUILD="$(plutil -extract CFBundleVersion raw -o - HALPlugin/Resources/Info.plist)"

test "$SOURCE_APP_VERSION" = "$SOURCE_APP_VERSION_BEFORE" || fail "source app version was modified to $SOURCE_APP_VERSION"
test "$SOURCE_APP_BUILD" = "$SOURCE_APP_BUILD_BEFORE" || fail "source app build was modified to $SOURCE_APP_BUILD"
test "$SOURCE_DRIVER_VERSION" = "$SOURCE_DRIVER_VERSION_BEFORE" || fail "source driver version was modified to $SOURCE_DRIVER_VERSION"
test "$SOURCE_DRIVER_BUILD" = "$SOURCE_DRIVER_BUILD_BEFORE" || fail "source driver build was modified to $SOURCE_DRIVER_BUILD"

printf 'build orchestration validation passed\n'
