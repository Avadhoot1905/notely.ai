---
name: ingestion
description: Load for any work on turning a meeting into a transcript then structured output — the end-to-end pipeline, its distinct stages, and (critically) the separate representations of raw audio, transcript, cleaned transcript, Meeting IR, and MOM that must not be collapsed.
---

# ingestion

## The stages (engine `pipeline/orchestrator.rs`)
```
audio → media/ (FFmpeg normalize + VAD) → asr/ (Qwen3-ASR) → raw Transcript
      → preprocess/ (normalize + chunk) → ai/ extraction (per chunk) → ai/ synthesis
      → ai/ validation → renderer/ (Markdown/HTML/JSON) → storage/
```
Transcript input skips media + ASR. Orchestration depends only on traits/helpers, never backends.

## The distinct representations (DO NOT collapse these)
1. **Raw audio** — PCM frames (`AudioFrame`, Flutter) / normalized WAV (engine `media/`).
2. **Raw Transcript** — canonical `domain::Transcript` straight from ASR. Preserved separately.
3. **Cleaned/normalized transcript** — deterministic `preprocess/` output (whitespace/order/
   timestamps) + segment-aware chunks. The raw ASR transcript is kept apart from the normalized copy.
4. **ChunkFindings** — per-chunk extraction output (`ai/findings.rs`), traceable to a `chunk_id`.
5. **Meeting IR** — consolidated, validated, evidence-linked structure (`domain/meeting_ir.rs`).
6. **MOM** — deterministic render of the IR. Derived; never authored by the LLM.

Each layer exists for a reason (scalability, provenance, debuggability). Merging them (e.g.
"transcript → LLM → MOM") is an architectural regression — see D-0014/D-0015.

## What is deterministic vs LLM
Deterministic (Rust): media/VAD/segment merge/timestamps, chunking, IR validation, MOM rendering,
evidence grounding, owner/deadline guard, participant backfill. LLM (Qwen3 1.7B via Ollama):
semantic extraction + synthesis only. Use the model only where language understanding is required.

## Status
- Proven end-to-end: transcript → … → MOM (`engine/tests/ollama_smoke.rs`).
- `audio → media → ASR` head is scaffolded; `whisper.rs` returns `NotImplemented`, so **audio input
  currently ends in a clean error**. A Flutter-side live-capture seam pipeline exists (see audio, asr)
  with ASR still mocked — it produces the live UI transcript, not persisted meeting enrichment yet.

## Persistence + recovery
Source (meeting + transcript) is saved **before** AI runs; enrichment status is separate. A crash or
AI failure never loses the capture — see crash-recovery, storage.

## Related skills
audio · asr · meeting-ir · extraction · synthesis · concurrency · crash-recovery · storage · testing
