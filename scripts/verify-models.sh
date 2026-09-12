#!/usr/bin/env bash
# Verify that the models required by the manifests are available locally.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Checking runtimes"
command -v ollama >/dev/null && echo "  ollama: found" || echo "  ollama: NOT found (needed for local LLM)"

# TODO(v0): for each manifest, confirm the model is present in its runtime/cache and
# matches the expected quantization. Exit non-zero on any missing model.
echo "NOTE: model verification is not implemented yet (scaffold)."
