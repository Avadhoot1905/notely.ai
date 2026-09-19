---
name: profiling
description: Load before optimizing anything in Notely — measure first, on the right layer, and attribute cost correctly (Notely code vs the external model runtime). Prevents optimizing code that isn't the bottleneck.
---

# profiling

## Rule
**Measure before optimizing.** No optimization without a before/after number on a realistic input.
The repo defines few budgets (performance-budget), so a claim of "slow" needs evidence.

## Attribute cost correctly
Much of Notely's wall-clock is **outside Notely's code**: the LLM (Ollama/MLX) and ASR run in
**separate server processes**. Before optimizing engine code, confirm the time isn't in the model.
- Compare model sizes (`qwen3:0.6b/1.7b/4b`) to isolate model vs pipeline cost.
- The **LLM result cache** (`llm_cache.db`) means repeat runs skip inference — profile cold vs warm.

## Where to measure
- **Engine (Rust):** `tracing` spans (`NOTELY_LOG_LEVEL=debug`); time the stage via the
  orchestrator's stage events; `cargo run --example transcript_to_mom` for an end-to-end sample;
  `criterion`-style micro-timing for deterministic stages (chunking, rendering, evidence grounding).
- **Search:** time FTS5 vs hybrid separately; brute-force vector cosine is linear in embedded passages
  (large-vault) — the usual suspect at scale.
- **Flutter:** DevTools timeline for jank; confirm heavy work isn't on the UI isolate; the audio path's
  bounded-buffer `dropped` counter signals a stalled consumer.

## Realistic inputs
Use `data/fixtures/transcripts/*.json`; for scale, generate a large synthetic vault rather than
guessing. Warm vs cold cache matters — state which you measured.

## Then optimize
Change the actual bottleneck, re-measure, keep the change minimal (minimal-change). If the bottleneck
is the model/runtime, the fix is config (model choice, cache), not engine code.

## Related skills
performance-budget · large-vault · ai-runtime · search · debugging
