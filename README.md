# Notely

> An open-source, **local-first** meeting intelligence app that turns multilingual
> conversations into structured, evidence-backed Minutes of Meeting (MOM) — without sending your
> meetings to the cloud.

**Status: v0 — architecture scaffolding.** The monorepo, module boundaries, and IPC contract are
in place; the processing pipeline is being implemented behind them.

No mandatory cloud service · no API key · no subscription.

---

## What Notely is

Most AI meeting assistants send your audio to cloud transcription and a cloud LLM. That brings
privacy risk, recurring cost, vendor lock-in, weak support for local/mixed-language meetings, and
little visibility into where an AI-generated claim came from.

Notely runs the whole thing on your machine:

```text
Meeting → local ASR → local LLM → structured Meeting IR → evidence-backed MOM
```

## v0 goal

> **Can we turn a meeting recording into a genuinely useful MOM, entirely locally?**

That is the whole bet for v0. Scope and non-goals: [docs/product.md](docs/product.md).

## Architecture overview

Two components, one boundary (IPC):

```text
Flutter Desktop App
        │
        │ IPC   (the single backend boundary)
        ▼
   Rust Engine
        │
        ├── media/     FFmpeg + VAD
        ├── asr/       speech recognition (Qwen3-ASR — separate runtime)
        ├── preprocess/ deterministic normalization + chunking
        ├── ai/        semantic analysis (extraction / synthesis / validation)
        ├── llm/       model runtime (Ollama, …)
        ├── storage/   local persistence
        └── renderer/  Meeting IR → Markdown / HTML / JSON
```

- **Flutter (`apps/desktop`)** owns all UI, navigation, and user interaction, and talks to the
  engine **only** over IPC. It contains no media/ASR/AI/model/storage/orchestration logic.
- **Rust (`engine`)** is the single local backend — one Cargo package, internally modular — that
  owns everything below the IPC line.

For v0 there is deliberately **one Rust engine** (not microservices, not many crates) and **one**
desktop app. Details: [docs/architecture.md](docs/architecture.md).

## Repository structure

```text
notely.ai/
├── apps/desktop/        Flutter desktop app (lib/app, lib/features, lib/ipc)
├── engine/              Rust engine — ONE package, internally modular
│   └── src/{ipc,domain,pipeline,media,asr,ai,llm,storage,renderer}/
├── packages/protocol/   canonical IPC contract shared by both sides (no logic)
├── models/manifests/    model METADATA only — never weights
├── data/fixtures/       small sample audio / transcripts / meeting_ir
├── docs/                flat documentation (architecture, ipc, pipeline, …)
├── scripts/             flat dev scripts (bootstrap, dev, check, test, build, …)
├── tools/               developer tooling
├── tests/               cross-cutting integration + evaluation
└── Cargo.toml, Makefile, justfile, rust-toolchain.toml, …
```

`docs/` and `scripts/` are intentionally **flat**. The Rust side is intentionally **one package**.

## Local-first philosophy

Meeting audio is sensitive, so the default is that everything stays on the user's machine:

```text
┌─────────────────────────────────────────┐
│              User's Machine             │
│        Audio → ASR → LLM → MOM          │
└─────────────────────────────────────────┘
```

Cloud providers may one day be optional adapters, but they are never required. Storage strategy:
[docs/storage.md](docs/storage.md).

## Flutter + Rust

| Flutter (`apps/desktop`) is responsible for | Rust (`engine`) is responsible for |
|---------------------------------------------|------------------------------------|
| UI, navigation, settings                    | media / FFmpeg / VAD               |
| meeting list & detail, transcript, MOM views | ASR                               |
| recording / import UI, progress display     | AI extraction / synthesis / validation |
| communicating with the engine over IPC      | LLM runtime, model loading         |
|                                             | storage, pipeline orchestration, rendering |

Flutter does **not** touch FFmpeg, ASR, Qwen, models, the database, or orchestration — those live
in Rust.

## IPC model

Flutter ↔ Rust communicate over a small, **versioned, serializable** protocol. The transport is
isolated so it can change later without rewriting the pipeline.

```text
Flutter                    IPC                     Engine (events)
 ├── StartMeeting                                   ├── JOB_CREATED
 ├── ImportMeeting          request ─▶              ├── TRANSCRIPTION_STARTED
 ├── GetMeeting                                     ├── TRANSCRIPTION_PROGRESS
 ├── GetTranscript          ◀─ event                ├── ANALYSIS_STARTED
 ├── GetMom                                         ├── MOM_GENERATED
 └── CancelJob                                      └── JOB_COMPLETED
```

Contract: [`packages/protocol`](packages/protocol/README.md) · design: [docs/ipc.md](docs/ipc.md).

## AI / ASR pipeline

```text
AUDIO → Qwen3-ASR → Transcript → deterministic Rust chunking/cleanup
      → small Qwen (extraction per chunk + synthesis) → Meeting IR
      → deterministic Rust renderer → Markdown
```

Two Qwen models on **two runtimes**, with deterministic Rust in between:

- **Qwen3-ASR** (speech recognition) runs on a **separate ASR runtime** — *not* Ollama.
- **Qwen3 1.7B** (meeting understanding) runs on **Ollama**; configurable via `NOTELY_LLM_MODEL`.
- **Rust** owns chunking, evidence grounding, validation, and rendering.

Extraction and synthesis are **two separate LLM passes** (never a single "transcript → LLM → MOM"
call). The pipeline coordinates components through **abstractions** (`AsrProvider`, `AiAnalyzer`,
`LlmProvider`) — never hard-wired to a backend. Evidence is grounded deterministically in Rust and
owners/deadlines are never invented. See [docs/pipeline.md](docs/pipeline.md) and
[docs/ai-engine.md](docs/ai-engine.md).

## Meeting IR

The **Meeting IR (Intermediate Representation)** is the heart of the system. The LLM outputs
**structured data**, not the final Markdown; a deterministic renderer produces the MOM.

```text
Transcript → Meeting IR (structured, validated, evidence-linked) → MOM
```

This gives traceability (every decision/action links to a transcript span), determinism, reuse,
and validation. Rationale: [docs/meeting-ir.md](docs/meeting-ir.md).

## Development

### Prerequisites

- **Rust** (stable, `rustup`) with `rustfmt` + `clippy` (see `rust-toolchain.toml`)
- **Flutter** (stable, Dart ≥ 3.12) with desktop support enabled
- Optional for real processing: **Ollama**, **FFmpeg**, a Whisper backend
- Optional: **just** (otherwise use `make` or `scripts/`)

### Common commands

```bash
./scripts/bootstrap.sh      # verify toolchains, fetch deps
./scripts/dev.sh            # run engine + desktop together
./scripts/start-engine.sh   # cargo run -p notely-engine
./scripts/start-desktop.sh  # flutter run
./scripts/check.sh          # fmt + lint (Rust + Flutter)
./scripts/test.sh           # cargo test + flutter test
./scripts/build.sh          # release builds
```

Equivalent `make <target>` / `just <target>` recipes exist. Full guide:
[docs/development.md](docs/development.md).

### Models

Weights are **never** committed. Manifests live in `models/manifests/`; fetch the LLM with
`./scripts/download-models.sh` (`ollama pull qwen3:1.7b`). Qwen3-ASR runs on a separate runtime.
See [models/README.md](models/README.md).

## Current status

**Implemented (backend):**
- ✅ Single Rust engine, internally modular, runnable (`cargo run -p notely-engine`) with graceful shutdown
- ✅ Domain model + structured **Meeting IR** with evidence/provenance (serde)
- ✅ **Deterministic transcript preprocessing + chunking** (`preprocess/`) — segment-aware, with context
- ✅ **Two-pass AI**: per-chunk extraction → synthesis → validation; deterministic evidence grounding; owners/deadlines never invented
- ✅ LLM runtime abstraction over **Ollama**, default **`qwen3:1.7b`** (configurable via `NOTELY_LLM_MODEL`)
- ✅ **Qwen3-ASR** provider on a **separate runtime** (HTTP), Whisper optional — behind the `AsrProvider` trait
- ✅ SQLite storage (embedded, no server) behind repository traits
- ✅ Deterministic Markdown (table for action items) / JSON renderers — no LLM used to format
- ✅ Orchestrator with jobs, cancellation, and **granular per-stage progress events**
- ✅ Versioned IPC server over a transport-isolated TCP JSON socket
- ✅ **End-to-end proven** against real local **Qwen3 1.7B**: transcript → chunking → extraction → synthesis → Meeting IR → Markdown (`--ignored` smoke test)
- ✅ `cargo fmt/clippy/test` green (unit + integration tests)

**Scaffolded (clean boundary, not run end-to-end here):**
- ⏳ `audio → media → ASR` head: FFmpeg normalization + Qwen3-ASR HTTP client implemented; running it live needs FFmpeg installed and a reachable Qwen3-ASR runtime (transcript input is the supported path)
- ⏳ HTML renderer (Markdown + JSON done); a distinct verified-mode LLM pass
- ⏳ Flutter UI and the Dart IPC client (backend-only tasks so far)

See per-area status in [docs/](docs/) (`pipeline.md`, `ai-engine.md`, `ipc.md`).

## Roadmap

- **Phase 0 — Architecture (now):** Meeting IR, transcript schema, provider interfaces, IPC,
  storage strategy, evaluation dataset.
- **Phase 1 — Minimal pipeline:** import → local ASR → Ollama/Qwen → Meeting IR → Markdown MOM.
- **Phase 2 — Better intelligence:** diarization, decisions/action items, topics, questions, risks.
- **Phase 3 — Reliability:** evidence/provenance, verification pass, long-meeting handling.
- **Phase 4 — UX:** live recording/transcription, search, meeting history, human notes.
- **Phase 5 — Integrations (optional):** calendar, tickets, export, API.

Decision log: [docs/decisions.md](docs/decisions.md). Open research questions:
[docs/research.md](docs/research.md).

---

## License

MIT (see `license` in `Cargo.toml`). A dedicated `LICENSE` file will be added if/when needed —
for now this section is the reference.

## Contributing

Early days. Keep changes small and aligned with the boundaries above:

- One Rust engine, internally modular — don't split into crates.
- `docs/` and `scripts/` stay flat.
- IPC changes update **all three** of `packages/protocol`, the Rust `ipc` side, and the Dart
  `ipc` side, and bump the protocol version.
- Flutter never depends on engine internals — only on the IPC protocol.
- Run `./scripts/check.sh` and `./scripts/test.sh` before opening a PR.

## Security

Notely is local-first: meeting data stays on your machine and nothing is required to leave it.
Please report security concerns privately via a GitHub security advisory rather than a public
issue.
