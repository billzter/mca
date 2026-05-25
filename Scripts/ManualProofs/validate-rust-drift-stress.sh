#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR/Rust/mixed-audio-engine"

cargo test --test drift_stress_tests

printf 'Rust synthetic drift stress validation passed\n'
