# Pipeline

The pipeline (`engine/src/pipeline/`) owns **orchestration** — the order of stages and the
progress events they emit. It contains **no** provider-specific implementations; it depends only
on the abstractions each module exposes.

```text
input (audio OR transcript)
    ↓
media processing        (media/)      FFmpeg → normalized mono audio      [audio only]
    ↓
ASR                     (asr/)        Qwen3-ASR (separate runtime) → raw Transcript  [audio only]
    ↓
deterministic prep      (preprocess/) normalize (whitespace/order/timestamps) + chunk
    ↓
AI extraction           (ai/)         per chunk: Qwen3 1.7B → ChunkFindings (+ grounded evidence)
    ↓
AI synthesis            (ai/)         consolidate findings → Meeting IR; reconcile provenance
    ↓
Meeting IR validation   (ai/)         deterministic structural checks
    ↓
rendering               (renderer/)   deterministic IR → Markdown / JSON
    ↓
storage                 (storage/)    persist meeting, raw transcript, IR, MOM
```

If the input is already a transcript, the media + ASR stages are skipped.

## Responsibilities

- The **orchestrator** (`pipeline/orchestrator.rs`) sequences the stages and emits granular IPC
  events per stage (see below) via a job. It calls the two AI passes explicitly —
  `extract_chunk` per chunk, then `synthesize` — so it can report extraction progress.
- Each stage is reached through a **trait or deterministic helper**, never a concrete backend:
  `AsrProvider`, `AiAnalyzer`, `LlmProvider`, `Store`, `preprocess::prepare`, `renderer::markdown`.
- **Jobs** (`pipeline/jobs.rs`) model a tracked, cancellable run; cancellation is checked between
  stages and between chunks.

This keeps the ordering logic stable while implementations are swapped underneath.

## Progress events

Emitted on the IPC event stream (`ipc/events.rs`); granular where a stage can measure it,
stage-level otherwise (never faked):

```text
JobCreated → ProcessingStarted
  → MediaProcessingStarted/Completed        [audio only]
  → TranscriptionStarted/Completed          [audio only]
  → ChunkingStarted/Completed{chunk_count}
  → ExtractionStarted{n} → ExtractionProgress{i/n}… → ExtractionCompleted
  → SynthesisStarted/Completed
  → ValidationStarted/Completed
  → RenderingStarted/Completed
  → JobCompleted | JobFailed
```

## Status (v0)

- **Implemented and proven end-to-end** (`transcript → chunking → Qwen3 1.7B extraction →
  synthesis → Meeting IR → Markdown`) against a real local model — see
  `engine/tests/ollama_smoke.rs` and `cargo run --example transcript_to_mom`.
- **Scaffolded (clean boundary, not run end-to-end here):** the `audio → media → ASR` head.
  FFmpeg normalization is implemented; Qwen3-ASR is implemented as an HTTP client to a separate
  runtime. Running it live needs FFmpeg installed and a Qwen3-ASR runtime reachable.

## Processing modes (planned)

The same reasoning model can run a **fast** path (skip the validation/verify stage) or a
**verified** path (run it). Verification is an optional quality/cost tradeoff, not a structural
requirement. See [ai-engine.md](ai-engine.md).

## What is deterministic vs. LLM

| Deterministic (traditional code)                    | LLM                          |
|-----------------------------------------------------|------------------------------|
| audio extraction, VAD, segment merging, timestamps  | semantic extraction          |
| Meeting IR JSON validation                          | synthesis / summarization    |
| MOM rendering (templates)                           | verification (language judgement) |

Use the LLM only where language understanding is actually required.

## Status (v0)

- **Implemented:** the orchestrator (`pipeline/orchestrator.rs`) drives create-meeting →
  (transcript) → AI analyze → render → store, emitting events and honoring cancellation between
  stages; the in-memory job registry (`pipeline/jobs.rs`); the AI, storage (SQLite), and Markdown
  renderer stages. The **transcript → Meeting IR → Markdown → storage** path is proven end-to-end
  against Ollama/Qwen (`engine/tests/ollama_smoke.rs`).
- **Scaffolded / not wired end-to-end:** the **audio → media → ASR** path. `media` (FFmpeg) is
  implemented and `asr` has a real trait + fixture provider, but the Whisper backend returns
  "not implemented", so audio input currently ends in a clean error, not a transcript.
- **Planned:** VAD-based chunking, diarization, and the optional verified-mode reasoning pass.
