---
name: ollama
description: Load when working on Notely's default LLM runtime — the Ollama provider (generate/health/embed), its config knobs, cross-platform GPU behavior, and the smoke test. Ollama serves meeting understanding only, never ASR.
---

# ollama

## Role
Ollama is the **default LLM runtime** (`engine/src/llm/ollama.rs`), cross-platform. It serves
**meeting understanding** (default model `qwen3:1.7b`) — extraction, synthesis, QA, and (if enabled)
embeddings. It does **not** do ASR (that's a separate Qwen3-ASR runtime — see asr).

## What the provider implements
`generate`, `health`, and `embed` (via `/api/embed`, so Ollama can back hybrid search). It's reached
over HTTP behind `LlmProvider`; the AI layer never talks to it directly. Structured output uses
Ollama's `format` field with the Rust-owned JSON schema (D-0007).

## Config (`config.rs`, `.env.example`, `docs/development.md`)
- `NOTELY_LLM_PROVIDER=ollama` (default).
- `NOTELY_OLLAMA_URL` = `http://localhost:11434`.
- `NOTELY_LLM_MODEL` = `qwen3:1.7b` (legacy alias `NOTELY_OLLAMA_MODEL`). Swap to `qwen3:0.6b`/
  `qwen3:4b` to benchmark without touching the pipeline (D-0012).
- `NOTELY_OLLAMA_TIMEOUT_SECS` = `180`.
- Per-task overrides: `NOTELY_LLM_MODEL_{EXTRACTION,SYNTHESIS,QA,EMBEDDING}`.

## GPU / platform
Ollama picks the accelerator automatically: **Metal** on Apple Silicon, **CUDA** on NVIDIA, CPU
otherwise. **No CUDA/Metal code lives in Notely** — acceleration is entirely Ollama's job (D-0021).
See apple-silicon, cuda.

## Setup & verification
`ollama pull qwen3:1.7b` (or `scripts/download-models.sh`); `scripts/verify-models.sh` checks it's
present; manifest in `models/manifests/qwen3.yaml`. Weights are never in the repo.

## Testing
- End-to-end truth: `cargo test -p notely-engine --test ollama_smoke -- --ignored --nocapture`
  (ignored by default so the normal suite never depends on a running Ollama).
- Interactive: `cargo run -p notely-engine --example transcript_to_mom`.
- Unavailable Ollama → typed `LlmError`; the pipeline defers enrichment (retryable), Ask degrades.

## Related skills
ai-runtime · apple-silicon · cuda · extraction · synthesis · offline-first · testing
