#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT_DIR/Scripts/generate-rust-shared-memory-abi.sh" --check
cd "$ROOT_DIR/Rust/mixed-audio-engine"
cargo test

printf 'rust engine validation passed\n'
