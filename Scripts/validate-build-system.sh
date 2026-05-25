#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'build-system validation failed: %s\n' "$1" >&2
  exit 1
}

assert_file() {
  test -f "$1" || fail "missing file: $1"
}

assert_dir() {
  test -d "$1" || fail "missing directory: $1"
}

assert_dir App/Sources
assert_dir App/Resources
assert_dir Config
assert_dir HALPlugin/Sources
assert_dir HALPlugin/Include
assert_dir HALPlugin/Resources
assert_dir Generated/include
assert_dir Generated/lib/debug
assert_dir Generated/lib/release
assert_dir Rust/mixed-audio-engine/src
assert_dir Rust/mixed-audio-engine/tests
assert_dir TestArtifacts
assert_dir Tools/SharedMemoryProducer

assert_file App/Resources/Info.plist
assert_file App/MixedCaptureAudio.entitlements
assert_file .gitignore
assert_file .github/workflows/ci.yml
assert_file .github/workflows/release.yml
assert_file MixedCaptureAudio.xcworkspace/contents.xcworkspacedata
assert_file MixedCaptureAudio.xcodeproj/project.pbxproj
assert_file HALPlugin/Resources/Info.plist
assert_file HALPlugin/Include/MixedCaptureAudioCompatibility.h
assert_file HALPlugin/Include/MixedAudioSharedMemory.h
assert_file HALPlugin/Sources/MixedCaptureAudioDriver.c
assert_file Scripts/Support/build-audio-device-list.sh
assert_file Scripts/build-hal-driver.sh
assert_file Scripts/generate-rust-shared-memory-abi.sh
assert_file Scripts/Support/build-hal-smoke-tests.sh
assert_file Scripts/install-hal-driver.sh
assert_file Scripts/package-installer.sh
assert_file Scripts/package-signed-installer.sh
assert_file Scripts/notarize-package.sh
assert_file Scripts/install-public-signing-certs.sh
assert_file Scripts/mca-build
assert_file Scripts/reload-coreaudio.sh
assert_file Scripts/uninstall-mca.sh
assert_file Scripts/uninstall-hal-driver.sh
assert_file Scripts/validate-build-orchestration.sh
assert_file Scripts/validate-signing-config.sh
assert_file Scripts/validate-notarization-config.sh
assert_file Tools/HALDriverSmokeTests/MixedCaptureAudioDriverSmokeTests.c
assert_file Tools/AudioDeviceList/ListAudioDevices.c
assert_file Rust/mixed-audio-engine/src/generated_shared_memory_abi.rs

sh Scripts/build-hal-driver.sh >/tmp/mca-build-system-driver-build.log
test -d Build/Debug/MixedCaptureAudio.driver || fail "build did not create driver bundle"
test -f Build/Debug/MixedCaptureAudio.driver/Contents/MacOS/MixedCaptureAudio || fail "build did not create driver executable"
test -f Build/Debug/MixedCaptureAudio.driver/Contents/Info.plist || fail "build did not copy driver plist"
nm -gU Build/Debug/MixedCaptureAudio.driver/Contents/MacOS/MixedCaptureAudio | grep -q '_MixedCaptureAudio_Create' || fail "driver factory symbol is not exported"
otool -hv Build/Debug/MixedCaptureAudio.driver/Contents/MacOS/MixedCaptureAudio | grep -q ' BUNDLE ' || fail "driver executable is not a Mach-O bundle"
codesign --verify --deep --strict --verbose=4 Build/Debug/MixedCaptureAudio.driver >/tmp/mca-build-system-codesign.log 2>&1 || fail "driver bundle signature is invalid"
sh Scripts/Support/build-hal-smoke-tests.sh >/tmp/mca-build-system-smoke-build.log
Build/Debug/Tools/MixedCaptureAudioDriverSmokeTests >/tmp/mca-build-system-smoke-test.log
sh Scripts/Support/build-audio-device-list.sh >/tmp/mca-build-system-device-list-build.log

plutil -lint MixedCaptureAudio.xcodeproj/project.pbxproj >/tmp/mca-build-system-xcode-plist.log

printf 'build-system validation passed\n'
