#!/usr/bin/env bash
# Convenience: start the engine, then the desktop app.
# For real multi-process dev you'll usually run the two in separate terminals.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Starting engine in the background"
./scripts/start-engine.sh &
ENGINE_PID=$!
trap 'kill "$ENGINE_PID" 2>/dev/null || true' EXIT

echo "==> Starting desktop app"
./scripts/start-desktop.sh
