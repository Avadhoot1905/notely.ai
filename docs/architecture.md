# Architecture

Notely is a **local-first** desktop application for turning meetings into structured,
evidence-backed Minutes of Meeting (MOM). It has two parts and one boundary between them.

```text
Flutter Desktop App
        │
        │ IPC   (the single backend boundary)
        ▼
   Rust Engine
        │
        ├── media/       FFmpeg audio normalization + VAD boundary
        ├── asr/         speech recognition (Qwen3-ASR default, separate runtime)
        ├── preprocess/  deterministic normalization + chunking (Rust)
        ├── ai/          semantic analysis (extraction / synthesis / validation)
        ├── llm/         LLM runtime (Ollama → Qwen3 1.7B)
        ├── storage/     local persistence (SQLite)
        └── renderer/    Meeting IR → Markdown / HTML / JSON
```

## The v0 processing architecture

```text
                AUDIO
                  │
                  ▼
             Qwen3-ASR              (asr/  — separate ASR runtime, NOT Ollama)
                  │
                  ▼
              Transcript
                  │
                  ▼
          deterministic Rust        (preprocess/  — normalize + chunk)
          chunking / cleanup
                  │
                  ▼
             small Qwen             (ai/ over llm/ → Ollama → Qwen3 1.7B)
                  │
         ┌────────┴────────┐
         ▼                 ▼
     extraction        synthesis
     (per chunk)      (consolidate)
         │                 │
         └────────┬────────┘
                  ▼
              Meeting IR
                  │
                  ▼
          deterministic Rust        (renderer/  — templates, no LLM)
               renderer
                  │
                  ▼
             Markdown
```

**The key distinction — two Qwen models on two runtimes, with Rust in between:**

```text
Qwen3-ASR   = speech recognition        → its own ASR runtime (HTTP), not Ollama
Qwen3 1.7B  = meeting understanding      → Ollama
Rust        = deterministic orchestration / chunking / validation / rendering
```

Ollama does not do speech-to-text, so ASR is a genuinely separate runtime behind the
`AsrProvider` trait. The default LLM is the small **Qwen3 1.7B** (configurable via
`NOTELY_LLM_MODEL`). Extraction and synthesis are **two deliberately separate LLM passes** so the
system scales to long meetings, keeps provenance, and stays debuggable — never a single
"transcript → LLM → MOM" call.

## Two components

- **`apps/desktop` (Flutter):** all UI, navigation, and user interaction — meeting list/detail,
  transcript and MOM views, recording/import, progress display, settings. It talks to the
  engine **only** over IPC. It contains no media/ASR/AI/model/storage/orchestration logic.

- **`engine` (Rust):** the single local backend. One Cargo package, internally modular. It owns
  everything below the IPC line: media processing, ASR, AI reasoning, LLM runtime, storage, and
  rendering, coordinated by a pipeline orchestrator.

## Why one engine (not microservices / many crates)

For v0 there is deliberately **one Rust process and one Rust package**. The modules below give
clean internal boundaries without the cost of multiple crates, IPC hops, or deployment units.
The workspace is set up so we *can* split later — but we don't pay for that now. See
[decisions.md](decisions.md).

## Engine modules

| Module      | Responsibility                                                        | Must not know about |
|-------------|-----------------------------------------------------------------------|---------------------|
| `domain`    | Portable application concepts (Meeting, Transcript, Meeting IR, …)     | anything else       |
| `ipc`       | The Flutter↔Rust boundary: requests, responses, events, versioning     | pipeline internals  |
| `pipeline`  | Orchestration/ordering of the stages + jobs/events                    | provider specifics  |
| `media`     | FFmpeg audio extraction + VAD boundary                                | Flutter             |
| `asr`       | `AsrProvider` abstraction + Qwen3-ASR (default) / Whisper (optional)  | Flutter             |
| `preprocess`| Deterministic transcript normalization + chunking                    | LLMs / providers    |
| `ai`        | Two-pass semantic analysis over domain types                         | which runtime serves the model |
| `llm`       | `LlmProvider` runtime abstraction + Ollama impl                       | meeting semantics   |
| `storage`   | Local persistence behind repository traits                            | Flutter             |
| `renderer`  | Deterministic IR → Markdown/HTML/JSON                                 | LLMs                |

## Key principles

1. **IPC is the only boundary.** The transport can change without touching the pipeline.
2. **The domain is boring and portable.** Domain types depend on nothing but serialization.
3. **Provider/runtime boundaries are clean.** The pipeline depends on traits (`AsrProvider`,
   `AiProvider`, `LlmProvider`), never on Whisper/Qwen/Ollama directly.
4. **Structure over prose.** The LLM produces a structured [Meeting IR](meeting-ir.md); rendering
   is deterministic.
5. **Local-first.** Nothing is required to leave the machine.

See also: [ipc.md](ipc.md), [pipeline.md](pipeline.md), [ai-engine.md](ai-engine.md),
[meeting-ir.md](meeting-ir.md), [storage.md](storage.md).
