---
name: ai-runtime
description: Load when working on the LLM runtime layer — the LlmProvider abstraction (generate/health/embed), the transparent result cache, per-task model routing, and how runtimes (Ollama/MLX) sit behind a process/HTTP boundary. The seam between meaning and inference.
---

# ai-runtime

## The layering (keep these separate)
```
ai/   semantic ops over domain types (asks for meaning)
 └─ llm/  LlmProvider: generate · health · embed  (owns HOW a model runs)
     └─ CachingLlmProvider (transparent SQLite result cache)
         └─ Ollama (default) | MLX (macOS, opt-in)   — separate HTTP servers
             └─ model/provider (manifests; weights out-of-repo)
```
`provider` (runtime) and `model` (which weights + settings) are **separate concepts**, so a model can
be re-pointed at a different runtime without touching callers. The AI layer never knows which runtime
serves it and never speaks HTTP itself.

## `LlmProvider` (`engine/src/llm/provider.rs`)
- `generate(GenerateRequest) -> GenerateResponse` — `GenerateRequest{ model?, system?, prompt,
  format?, config, think }`. `format` is a JSON Schema for structured output; `think=false` by default.
  `GenerationConfig{ temperature?, num_ctx?, max_tokens? }`.
- `health()` — liveness of the runtime.
- `embed(...)` — **batch** embeddings; **defaults to `Unsupported`** so a runtime opts in only if it
  truly embeds. Callers degrade gracefully (search falls back to FTS5-only).
- Runtime selected by `NOTELY_LLM_PROVIDER` (`ollama` | `mlx`).

## Transparent result cache (`llm/cache.rs`, `llm_cache.db`) — D-0017
`CachingLlmProvider` wraps the chosen runtime. Identical requests (model + prompt + schema + params)
skip inference; **misses populate on success only** (a failed generation never poisons the cache); an
unavailable cache degrades to pass-through. Extraction/synthesis/QA are unaware it exists.

## Per-task model routing (config, not a framework) — D-0020
`NOTELY_LLM_MODEL_{EXTRACTION,SYNTHESIS,QA,EMBEDDING}` each override the model for that task; unset ⇒
runtime default. `NOTELY_LLM_MODEL_EMBEDDING` being set is what **turns on hybrid search**. No router
abstraction — just configuration.

## Adding a runtime
Implement `LlmProvider` behind the same trait as a **separate local server over HTTP** (like Ollama/
MLX). No pipeline changes; the AI layer is untouched. Never link an inference engine into the process.

## Related skills
ollama · apple-silicon · cuda · extraction · synthesis · search · offline-first · api-contracts
