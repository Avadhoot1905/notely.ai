#!/usr/bin/env bash
# Run the Rust engine.
set -euo pipefail
cd "$(dirname "$0")/.."

exec cargo run -p notely-engine "$@"
