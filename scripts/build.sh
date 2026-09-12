#!/usr/bin/env bash
# Produce release builds of the engine and the desktop app for the host platform.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building engine (release)"
cargo build -p notely-engine --release

echo "==> Building desktop app (release)"
cd apps/desktop
case "$(uname -s)" in
  Darwin) flutter build macos ;;
  *)      echo "Add the appropriate 'flutter build <platform>' for this OS." ;;
esac
