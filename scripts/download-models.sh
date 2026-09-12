#!/usr/bin/env bash
# Pull the local models Notely needs, into the runtime's own store (never into this repo).
#
# LLM weights live in Ollama's model store; nothing is written under the working tree.
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL="${NOTELY_LLM_MODEL:-${NOTELY_OLLAMA_MODEL:-qwen3:1.7b}}"

echo "==> Model manifests:"
ls models/manifests/

if ! command -v ollama >/dev/null; then
  echo "ERROR: 'ollama' not found. Install from https://ollama.com and re-run." >&2
  exit 1
fi

echo "==> Pulling LLM (meeting understanding) via Ollama: $MODEL"
ollama pull "$MODEL"

echo "==> Done. LLM weights are stored by Ollama (e.g. ~/.ollama/models), not in this repo."
echo "    ASR: Qwen3-ASR runs on a SEPARATE runtime (not Ollama). Ollama cannot serve ASR."
echo "    Provide a local Qwen3-ASR HTTP runtime and set NOTELY_ASR_URL. See models/manifests/qwen3-asr.yaml."
