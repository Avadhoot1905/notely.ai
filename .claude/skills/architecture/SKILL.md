---
name: architecture
description: Load for any non-trivial Notely change to understand the two components, the single IPC boundary, the audio→transcript→IR→MOM pipeline, and the invariants that must not be violated. The mental model that keeps changes in the right place.
---

# architecture

## The shape
Two components, one boundary:

```
Flutter desktop app (apps/desktop)  ──IPC──▶  Rust engine (engine)
```

The Flutter app is **all UI and interaction**; it contains no media/ASR/AI/model/storage/
orchestration logic. The engine owns everything below the IPC line. IPC (`PROTOCOL_VERSION=4`) is
the *only* backend boundary — transport can change without touching the pipeline.

## The processing pipeline (engine)
```
input (audio OR transcript)
  → media/      FFmpeg normalize + VAD boundary          [audio only]
  → asr/        Qwen3-ASR (separate HTTP runtime) → raw Transcript  [audio only]
  → preprocess/ deterministic normalize + segment-aware chunking (Rust, no LLM)
  → ai/         extraction (per chunk → ChunkFindings) then synthesis (→ Meeting IR)
  → ai/         deterministic Meeting IR validation
  → renderer/   deterministic IR → Markdown/HTML/JSON (no LLM)
  → storage/    persist meeting + transcript + IR + MOM + processing status
```
If input is already a transcript, media + ASR are skipped. Orchestration lives in
`pipeline/orchestrator.rs`; it depends only on traits/helpers, never concrete backends.

## The two-Qwen / two-runtime distinction (do not conflate)
- **Qwen3-ASR** = speech recognition, its own HTTP runtime — **not** Ollama (Ollama can't do STT).
- **Qwen3 1.7B** = meeting understanding, on **Ollama** (default LLM; `NOTELY_LLM_MODEL`).
- **Rust** = deterministic orchestration/chunking/validation/rendering/provenance in between.

## Layered AI boundary
`ai/` asks for *meaning* over domain types → `llm/` owns *how* a model runs behind `LlmProvider`
→ model/provider (manifests, weights out-of-repo). The AI layer never knows which runtime serves it.
See ai-runtime, extraction, synthesis.

## Invariants (violating these is a design regression)
1. **IPC is the only boundary.** Flutter never depends on engine internals.
2. **Two separate LLM passes** — never collapse to `transcript → LLM → MOM`.
3. **LLM outputs structured Meeting IR; rendering is deterministic.** No LLM used merely to format.
4. **Provenance/anti-invention is Rust's job**, not the model's (evidence grounding, owner/deadline guard).
5. **Source saved before AI runs** → "AI failure ≠ data loss"; enrichment status is a separate artifact.
6. **Local-first / offline.** Nothing is required to leave the machine; features degrade, not fail.
7. **Provider boundaries are clean.** Pipeline depends on `AsrProvider`/`AiAnalyzer`/`LlmProvider`/`Store`.
8. **The domain is portable** — `domain/` depends on nothing but serialization.

## Status reality (v0)
- Proven end-to-end: `transcript → chunking → Qwen3 1.7B extraction → synthesis → IR → Markdown →
  storage` (`engine/tests/ollama_smoke.rs`).
- Scaffolded, not wired end-to-end: `audio → media → ASR`. `media` (FFmpeg) is real; `whisper.rs`
  returns `NotImplemented`, so audio input currently ends in a clean error. A **Flutter-side live
  audio seam** (capture→VAD→segment→ASR seam) is being built with ASR still mocked — see audio/asr.

## Related skills
repo-navigation · ipc · ingestion · meeting-ir · ai-runtime · storage · offline-first · notely-maintainer
