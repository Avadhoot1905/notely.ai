#!/usr/bin/env bash
# Verify the runtime and the model Notely needs are available locally.
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL="${NOTELY_LLM_MODEL:-${NOTELY_OLLAMA_MODEL:-qwen3:1.7b}}"
URL="${NOTELY_OLLAMA_URL:-http://localhost:11434}"
ASR_URL="${NOTELY_ASR_URL:-http://localhost:9000}"
status=0

echo "==> Checking Ollama runtime (LLM)"
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

echo "==> Checking ASR runtime (Qwen3-ASR, separate from Ollama) at $ASR_URL"
if curl -sf -m 5 "$ASR_URL" >/dev/null 2>&1 || curl -sf -m 5 "$ASR_URL/health" >/dev/null 2>&1; then
  echo "  asr runtime: reachable"
else
  echo "  asr runtime: not reachable (optional — only needed for audio input; transcript input works without it)"
fi

if [ "$status" -eq 0 ]; then
  echo "==> LLM checks passed"
else
  echo "==> Some LLM checks failed" >&2
fi
exit "$status"
