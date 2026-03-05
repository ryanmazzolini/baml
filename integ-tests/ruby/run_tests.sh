#!/bin/bash

# Run Ruby integration tests

set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Build the Rust CFFI library (no-ops if already up to date)
cargo build --manifest-path "$REPO_ROOT/engine/Cargo.toml" -p baml_cffi

# Generate the Ruby client and run all tests
cd "$SCRIPT_DIR"
export BAML_LIBRARY_PATH="$REPO_ROOT/engine/target/debug/libbaml_cffi.so"
bundle exec rake generate test "$@"
