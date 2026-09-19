---
name: apple-silicon
description: Load when working on the macOS/Apple-Silicon acceleration path — the opt-in MLX provider (external mlx_lm.server behind HTTP), how it differs from Ollama-on-Metal, and the macOS-only, never-linked constraint. Also the reference platform for build/QA.
---

# apple-silicon

## Two macOS LLM paths
1. **Ollama on Metal** (default) — automatic; nothing macOS-specific in Notely.
2. **MLX** (`engine/src/llm/mlx.rs`, opt-in feature `mlx`, `NOTELY_LLM_PROVIDER=mlx`) — an
   Apple-Silicon path via an **external `mlx_lm.server`** (OpenAI-compatible), reached over local
   HTTP. **MLX is never linked into the Rust process** — same process/HTTP-boundary pattern as Ollama
   and ASR (D-0021).

## MLX rules
- **macOS-only and opt-in.** Linux/Windows keep Ollama unchanged; enabling MLX must not affect them.
- If the `mlx_lm.server` isn't running, the engine **defers** work rather than crashing.
- Config: `NOTELY_MLX_URL` (`http://localhost:8080`), `NOTELY_MLX_MODEL` (defaults to `NOTELY_LLM_MODEL`),
  `NOTELY_MLX_TIMEOUT_SECS` (180). A future GPU runtime (vLLM/llama.cpp) slots in identically.

## Memory considerations
The model runs in the **separate server**, not the engine — Notely's own memory footprint doesn't
include weights. Model size (`qwen3:0.6b/1.7b/4b`) is the main knob for a laptop; the two-pass +
deterministic-grounding design keeps the small default viable (D-0012).

## Platform status (this is the reference host)
macOS (Apple Silicon) is the **build/test/launch-verified** platform: `flutter build macos`, unit
tests, and app launch all pass here. The macOS meeting/companion native runtime
(`macos/Runner/MainFlutterWindow.swift`) is the reference implementation for the `notely/*` channels.
Interactive GUI QA is still recommended before release (see compatibility-matrix).

## Testing expectations
Don't assume MLX is running in tests; it's opt-in. LLM-dependent behavior is proven via the
Ollama smoke test, not MLX. Verify MLX manually when changing `mlx.rs`.

## Related skills
ai-runtime · ollama · cuda · compatibility-matrix · desktop · offline-first
