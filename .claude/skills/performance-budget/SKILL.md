---
name: performance-budget
description: Load when reasoning about performance targets. Notely defines FEW explicit numeric budgets — this skill lists the ones grounded in the repo, separates the concern areas, and insists you measure rather than invent numbers.
---

# performance-budget

## The honest state
Notely has **few hard numeric budgets** in-repo. Don't invent them (no-speculation). What the repo
*does* fix, and the concern areas to reason about, are below. Measure before claiming a target
(profiling).

## Grounded facts (from the code/config)
- **Detection poll:** ~2 s (macOS CoreAudio / Windows WASAPI `SetTimer` / Linux `pactl` via
  `g_timeout_add_seconds`). Idle cost should stay reasonable at this cadence.
- **Timeouts:** LLM per-generation `NOTELY_OLLAMA_TIMEOUT_SECS`=180 / `NOTELY_MLX_TIMEOUT_SECS`=180;
  ASR `NOTELY_ASR_TIMEOUT_SECS`=600. These bound worst-case latency, not target latency.
- **Default LLM** `qwen3:1.7b` chosen to be **fast on a dev laptop** (D-0012); model size is the main
  latency/quality dial.
- **Audio buffer:** `AudioIngestion` capacity 512 frames, drop-oldest (bounds memory under stall).
- **Segmenter:** max segment 30 s (bounds ASR unit size); pre-roll 300 ms, hangover 600 ms.

## Concern areas (reason about separately)
- **UI responsiveness** — capture never blocks the recorder callback; UI reads a folded snapshot, not
  raw frames. Keep the main isolate free of heavy work.
- **Ingestion latency** — VAD→segment→ASR seam; segment size caps how quickly text appears.
- **ASR / inference latency** — dominated by the external runtime + model size, not Notely code.
- **Search latency** — FTS5 fast; brute-force vector search is linear (large-vault).
- **Memory** — weights live in the *separate* runtime process, not the engine; watch bounded buffers
  and list rendering.
- **Storage / startup** — startup requeues jobs + opens DBs; a large first-time index is the main cost.

## Rule
Set a budget only with a measurement or an explicit product decision behind it. Otherwise state the
concern and defer the number.

## Related skills
profiling · large-vault · audio · ai-runtime · flutter-ui · no-speculation
