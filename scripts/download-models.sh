#!/usr/bin/env bash
# Pull the local models Notely needs, into the runtime's own store (never into this repo).
#
# LLM weights live in Ollama's model store; nothing is written under the working tree.
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL="${NOTELY_OLLAMA_MODEL:-qwen3:4b}"

echo "==> Model manifests:"
ls models/manifests/

if ! command -v ollama >/dev/null; then
  echo "ERROR: 'ollama' not found. Install from https://ollama.com and re-run." >&2
  exit 1
fi

echo "==> Pulling LLM model via Ollama: $MODEL"
ollama pull "$MODEL"

echo "==> Done. Weights are stored by Ollama (e.g. ~/.ollama/models), not in this repo."
echo "    ASR (Whisper) integration is not implemented yet; no ASR model is pulled."
