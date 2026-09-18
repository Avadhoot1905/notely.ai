# AI engine

Notely separates four concepts that are often conflated. Keeping them distinct is what lets the
system stay model-agnostic and produce traceable output.

```text
┌─────────────────────────────────────────────────────────────┐
│ AI semantic operations   (engine/src/ai)                    │
│   extraction · synthesis · validation                       │
│   works with DOMAIN types, asks for meaning                 │
└───────────────┬─────────────────────────────────────────────┘
                │ asks for generations
                ▼
┌─────────────────────────────────────────────────────────────┐
│ LLM runtime              (engine/src/llm)                   │
│   LlmProvider: generate · health · embed                    │
│   CachingLlmProvider  (transparent SQLite result cache)     │
│     └── Ollama (default, cross-platform) | MLX (macOS)      │
└───────────────┬─────────────────────────────────────────────┘
                │ runs
                ▼
┌─────────────────────────────────────────────────────────────┐
│ Model / provider         (models/manifests, llm/model.rs)   │
│   Qwen3, Gemma, … — name + settings, weights out-of-repo    │
└─────────────────────────────────────────────────────────────┘

                 all of the above produce / operate on
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Structured Meeting IR    (engine/src/domain/meeting_ir.rs)  │
│   the stable, structured output — NOT prose                 │
└─────────────────────────────────────────────────────────────┘
```

## AI semantic operations (`ai/`)

The reasoning layer. It works with **domain types**, not UI concepts, and is split into:

- **extraction** — pull discrete facts (decisions, action items, participants) out of the
  transcript, each linked to `Evidence` (a transcript time span).
- **synthesis** — compose higher-level understanding (summary, topics) and assemble the IR.
- **validation** — check the IR for consistency and evidence coverage; optionally an LLM
  verification pass.

Crucially, the AI layer **asks for semantic operations**. It does not know or care whether
inference runs through Ollama, llama.cpp, or anything else.

## LLM runtime (`llm/`)

Owns *how* a model is executed, behind `LlmProvider`. `provider` (the runtime) and `model` (which
model + settings) are separate concepts so a model can be re-pointed at a different runtime without
touching callers.

The trait exposes exactly the capabilities Notely needs — `generate`, `health`, and `embed` (batch
embeddings for hybrid search). `embed` is defaulted to `Unsupported`, so a runtime opts in only if
it truly embeds; callers degrade gracefully otherwise.

**Runtimes** (all behind the same trait, selected by `NOTELY_LLM_PROVIDER`):

- **Ollama** (`llm/ollama.rs`, default) — the cross-platform path. Uses CUDA on NVIDIA and Metal on
  macOS automatically; implements `generate`/`health`/`embed` (`/api/embed`).
- **MLX** (`llm/mlx.rs`, opt-in `mlx`) — an Apple-Silicon path. MLX is **never linked into the
  process**; like Ollama and ASR it runs as a *separate local HTTP server* (`mlx_lm.server`,
  OpenAI-compatible). An unreachable server just defers work — it never crashes, and Linux/Windows
  are unaffected. A future GPU runtime (e.g. vLLM) would slot in the same way.

**Result cache** (`llm/cache.rs`) — `CachingLlmProvider` transparently wraps the chosen runtime.
Identical requests (same model + prompt + schema + params) skip inference; misses populate on
**success only** (a failed generation never poisons the cache); an unavailable cache degrades to
plain pass-through. Extraction/synthesis/QA are unaware it exists. Backed by its own rebuildable
`llm_cache.db`.

**Per-task model routing** — extraction, synthesis, QA, and embedding can each use a different
model (`NOTELY_LLM_MODEL_EXTRACTION`/`_SYNTHESIS`/`_QA`/`_EMBEDDING`). Unset means "use the runtime
default", so nothing changes unless you opt in. This is plain configuration, not a routing
framework.

## Model / provider

Described by manifests in [`models/`](../models/README.md). **Weights are never in the repo.**

## Why structured IR, not direct MOM

The LLM outputs the **Meeting IR** (structured data), and a deterministic renderer produces the
MOM. This is the core design choice — see [meeting-ir.md](meeting-ir.md).

## Two passes (extraction + synthesis)

The AI layer runs **two deliberately separate LLM passes** over Rust-owned JSON schemas
(`ai/schema.rs`):

1. **Extraction** (`ai/extraction.rs`) — one schema-constrained call **per chunk** →
   `ChunkFindings` (`ai/findings.rs`). Findings are kept separate from the final IR so long
   meetings, provenance, and debugging stay tractable.
2. **Synthesis** (`ai/synthesis.rs`) — one call consolidating all findings → `MeetingIr`
   (dedup/merge + overall summary), followed by **deterministic reconciliation** in Rust.

Splitting the passes gives scalability to long meetings, provenance, easier evaluation, and the
ability to change chunking independently of prompts. We never collapse this into
`transcript → LLM → MOM`.

## Provenance & anti-invention (deterministic Rust)

Small models are unreliable at copying quotes and don't always surface owners/deadlines, so Rust
does the trustworthy work:

- **Evidence grounding** (extraction): each finding is matched back to its source transcript
  segment; Rust attaches the real quote + precise timestamps + speaker + `chunk_id`. Quotes the
  model *did* copy are kept and back-stamped.
- **Owner/deadline guard** (synthesis reconciliation): an owner/deadline is kept only if a source
  finding stated it or it appears verbatim in the transcript — otherwise it is dropped to `null`.
  The model may **not** invent people or dates.
- **Participant backfill:** participants come from the transcript speakers, not the model.
- **Controlled repair:** a parse failure triggers one stricter retry before erroring; malformed
  output is never accepted as a valid IR.

## Status (v0)

- **Implemented & proven end-to-end** against real local **Qwen3 1.7B** (`ollama_smoke.rs`):
  per-chunk extraction → synthesis → validation → grounded, provenance-linked Meeting IR.
- **Model is configurable** (`NOTELY_LLM_MODEL`) — benchmark `qwen3:0.6b` / `qwen3:4b` without
  touching the pipeline. Per-task overrides route extraction/synthesis/QA/embedding independently.
- **Runtimes behind `LlmProvider`:** Ollama (default) and MLX (opt-in, macOS) ship today; a
  transparent result cache wraps whichever is selected. Further runtimes (llama.cpp, vLLM, …) can
  be added without touching the pipeline.
- **Scaffolded / planned:** a distinct verified-mode critique pass.

The schemas are owned by Rust (`ai/schema.rs`) and mirror the domain types — the model fills them
in, it does not define them.
