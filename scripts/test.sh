#!/usr/bin/env bash
# Run the full test suite: Rust engine + Flutter app.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Rust tests"
cargo test

echo "==> Flutter tests"
( cd apps/desktop && flutter test )

echo "==> All tests passed"
