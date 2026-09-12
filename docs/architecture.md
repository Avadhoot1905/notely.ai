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
        ├── media/     FFmpeg + VAD
        ├── asr/       speech recognition (Whisper)
        ├── ai/        semantic analysis (extraction / synthesis / validation)
        ├── llm/       model runtime (Ollama, …)
        ├── storage/   local persistence
        └── renderer/  Meeting IR → Markdown / HTML / JSON
```

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
| `pipeline`  | Orchestration/ordering of the stages                                  | provider specifics  |
| `media`     | FFmpeg audio extraction + VAD                                         | Flutter             |
| `asr`       | `AsrProvider` abstraction + Whisper impl                              | Flutter             |
| `ai`        | Semantic analysis over domain types                                  | which runtime serves the model |
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
