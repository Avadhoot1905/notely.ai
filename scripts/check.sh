#!/usr/bin/env bash
# Fast static checks: formatting + linting for both sides. Run before committing.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Rust: fmt check"
cargo fmt --check

echo "==> Rust: clippy"
cargo clippy --all-targets -- -D warnings

echo "==> Flutter: format check"
( cd apps/desktop && dart format --output=none --set-exit-if-changed lib test integration_test )

echo "==> Flutter: analyze"
( cd apps/desktop && flutter analyze )

echo "==> All checks passed"
