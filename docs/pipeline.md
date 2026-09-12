# Pipeline

The pipeline (`engine/src/pipeline/`) owns **orchestration** — the order of stages and the
progress events they emit. It contains **no** provider-specific implementations; it depends only
on the abstractions each module exposes.

```text
input meeting
    ↓
media processing        (media/)   FFmpeg extract/normalize → VAD segment
    ↓
ASR                     (asr/)     AsrProvider → canonical Transcript
    ↓
transcript processing   (domain)   merge segments, attach speakers, cleanup
    ↓
AI extraction           (ai/)      decisions / action items / participants (+ evidence)
    ↓
AI synthesis            (ai/)      summary, topic grouping → assemble Meeting IR
    ↓
Meeting IR validation   (ai/)      structural + evidence checks (optional LLM verify pass)
    ↓
rendering               (renderer/) deterministic IR → Markdown / HTML / JSON
    ↓
storage                 (storage/) persist meeting, transcript, IR, MOM
```

## Responsibilities

- The **orchestrator** (`pipeline/orchestrator.rs`) sequences the stages and emits IPC events
  (`TRANSCRIPTION_PROGRESS`, `ANALYSIS_STARTED`, `MOM_GENERATED`, …) via a job.
- Each stage is reached through a **trait**, not a concrete backend:
  `AsrProvider`, `AiProvider`, `LlmProvider`, repository traits, renderer functions.
- **Jobs** (`pipeline/jobs.rs`) model a tracked run so the UI can show progress and cancel.

This keeps the ordering logic stable while implementations are swapped underneath.

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
