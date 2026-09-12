#!/usr/bin/env bash
# Verify the runtime and the model Notely needs are available locally.
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL="${NOTELY_OLLAMA_MODEL:-qwen3:4b}"
URL="${NOTELY_OLLAMA_URL:-http://localhost:11434}"
status=0

echo "==> Checking Ollama runtime"
if command -v ollama >/dev/null; then
  echo "  ollama: found ($(ollama --version 2>/dev/null | head -1))"
else
  echo "  ollama: NOT found (install from https://ollama.com)" >&2
  status=1
fi

echo "==> Checking Ollama service at $URL"
if curl -sf -m 5 "$URL/api/tags" >/dev/null 2>&1; then
  echo "  service: reachable"
else
  echo "  service: NOT reachable (start it with 'ollama serve')" >&2
  status=1
fi

echo "==> Checking model: $MODEL"
if command -v ollama >/dev/null && ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL"; then
  echo "  model: present"
else
  echo "  model: MISSING (run: ollama pull $MODEL)" >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "==> All model checks passed"
else
  echo "==> Some checks failed" >&2
fi
exit "$status"
