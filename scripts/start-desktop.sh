#!/usr/bin/env bash
# Run the Flutter desktop app. Defaults to the host desktop platform.
set -euo pipefail
cd "$(dirname "$0")/.."

cd apps/desktop
exec flutter run "$@"
