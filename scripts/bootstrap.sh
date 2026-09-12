#!/usr/bin/env bash
# Install/verify toolchains and fetch dependencies for local development.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Checking toolchains"
command -v cargo   >/dev/null || { echo "Rust (cargo) not found — install from https://rustup.rs"; exit 1; }
command -v flutter >/dev/null || { echo "Flutter not found — install from https://flutter.dev"; exit 1; }

echo "==> Fetching Rust dependencies"
cargo fetch

echo "==> Fetching Flutter dependencies"
( cd apps/desktop && flutter pub get )

echo "==> Bootstrap complete"
