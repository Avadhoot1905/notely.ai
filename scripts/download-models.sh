#!/usr/bin/env bash
# Fetch the local models described by the manifests in models/manifests/.
#
# Model WEIGHTS are never stored in this repo. They are downloaded into a user/cache
# location (e.g. via Ollama, or a Whisper model cache) outside the working tree.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Model manifests:"
ls models/manifests/

# TODO(v0): read each manifest and pull the model via the appropriate runtime, e.g.:
#   ollama pull qwen3
# and download the configured Whisper model into its cache dir.
echo "NOTE: model download is not implemented yet (scaffold)."
echo "For now, pull models manually, e.g.: ollama pull qwen3"
