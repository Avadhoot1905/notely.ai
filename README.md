# Notely

> A **local-first desktop workspace** for your notes — that also quietly turns your meetings into
> evidence-backed minutes, entirely on your own machine.

Notely is two things behind one desktop app:

1. A **Markdown note workspace** — open a folder ("stash"), browse a live file tree, and write in an
   autosaving editor. Your notes are plain files you own, nothing more.
2. A **meeting companion** — Notely notices when you're in a call, offers to take notes from a
   floating overlay, and (via a local Rust engine) produces structured, source-linked Minutes of
   Meeting. No audio, transcript, or summary leaves your machine.

No mandatory cloud service · no API key · no subscription.

**Status: v0 — functional prototype.** The desktop app, the cross-platform native runtime, the
typed IPC boundary, and the local AI pipeline all exist and run. It is early and evolving, not
production-hardened. See [Project status](#project-status).

---

## Table of contents

- [What is Notely?](#what-is-notely)
- [Why Notely?](#why-notely)
- [Project status](#project-status)
- [Current capabilities](#current-capabilities)
- [Architecture](#architecture)
- [How it works](#how-it-works)
- [Platform support](#platform-support)
- [Getting started](#getting-started)
- [Repository structure](#repository-structure)
- [Development model](#development-model)
- [Contributing](#contributing)
- [Roadmap](#roadmap)
- [License](#license)

---

## What is Notely?

Most note apps make you copy meeting notes in by hand, and most AI meeting assistants ship your
audio to a cloud transcription service and a cloud LLM — which means privacy risk, recurring cost,
vendor lock-in, and little visibility into where an AI-generated claim actually came from.

Notely takes a different stance: your notes are **local Markdown files in a folder you choose**, and
the meeting intelligence runs **on your machine**. The desktop UI combines free-form writing with
structured navigation (in the spirit of tools like Obsidian and VS Code), and a separate local
engine does the heavy lifting — speech-to-text, analysis, and rendering — behind a clean boundary.

The v0 bet, in one line:

> **Can a local-first desktop app own your notes *and* turn a meeting into a genuinely useful,
> source-linked MOM — without anything leaving your machine?**

Scope and non-goals: [`docs/product.md`](docs/product.md).

## Why Notely?

Notely is worth reading as a codebase because it takes a clear position on a few things:

- **Local-first, by default.** Notes are plain files; meeting data lives in a local SQLite database
  and on-disk artifacts. Cloud providers may one day be *optional adapters*, but they are never
  required.
- **A real UI/engine split.** Flutter owns presentation and interaction. A Rust engine owns
  platform-independent application logic (media, ASR, analysis, storage, rendering). They talk
  **only** over a typed IPC contract, so each side can evolve independently.
- **Structured intelligence, not prose-from-a-prompt.** The LLM emits a validated **Meeting IR**
  (intermediate representation) with evidence links back to transcript spans; a deterministic Rust
  renderer produces the final Markdown. Owners and deadlines are never invented.
- **One product, three platforms.** A single Flutter UI runs on macOS, Windows, and Linux, with
  OS-specific behavior (meeting detection, notifications, the floating overlay) isolated behind
  native runtimes and Dart service interfaces.
- **A codebase meant to stay legible.** One Rust engine (internally modular, not a pile of crates),
  a flat `docs/` and `scripts/` layout, and explicit boundaries — chosen so the project stays
  understandable as it grows.

## Project status

Notely is **v0**. The core application architecture and primary workflows are functional, but the
project is actively evolving. Concretely, that means:

- The desktop app runs today: you can open a folder, browse and edit Markdown notes, and ask
  keyword questions over them — with **no engine and no models required**.
- The Rust engine runs today and has been proven **end-to-end** (transcript → chunking → extraction
  → synthesis → Meeting IR → Markdown) against a real local Qwen3 1.7B via Ollama.
- Meeting detection, OS notifications, and the floating companion overlay are implemented natively
  on all three platforms and **runtime-verified on macOS**; Windows and Linux are currently
  **compile-gated in CI** and need on-device QA (see [Platform support](#platform-support)).
- The IPC contract, module boundaries, and native service interfaces are stable enough to build on,
  but **APIs may still change**, some platform behavior is still being hardened, and the UX is still
  evolving.

This is a good moment to contribute: the shape is in place, and there is plenty of well-bounded
work.

## Current capabilities

Grouped by area, and limited to what actually works in the current tree.

### Note workspace
- Open or create a **stash** (a vault = a folder of Markdown files); switch between recents; the
  last stash is restored on launch.
- **File tree explorer** with create / rename / delete and live file-watching, so external edits
  show up.
- **Markdown editor** with debounced autosave that preserves each file's original line endings
  (LF/CRLF) and handles case-only renames on case-insensitive filesystems.
- **Ask panel**: source-grounded question answering over your stash. The Rust engine keeps an
  incremental full-text (FTS5) index of your notes on disk, retrieves the most relevant passages,
  and asks the local LLM to answer **citing only those sources** — every answer links back to the
  exact note and line range, which you can click to open. If the engine or its LLM isn't running,
  Ask degrades to offline keyword retrieval rather than failing (AI failure never loses your data).
- **Inbox**: captured meetings, each with a clear state — *Ready*, *Processing*, *AI deferred*, or
  *Failed*. Because the transcript (the source) is persisted **before** any AI runs, a capture is
  never lost when the model is unavailable; it lands in the Inbox as *AI deferred* and can be
  retried in one click when AI comes back. Retry re-uses the stored capture, so it never duplicates.
- Light/dark theme.

### Meeting companion
- **Meeting detection** from an OS signal — microphone in use **plus** a running conferencing app
  (Zoom, Teams, Discord, WhatsApp; browsers surface as a generic provider). App-running alone is not
  treated as a meeting.
- A **real OS notification** prompt ("you're in a meeting — take notes?") with Start / Dismiss
  actions.
- A **floating companion overlay** — a separate always-on-top native window (its own Flutter engine)
  showing elapsed time and the live transcript, with pause / resume / stop / open-in-Notely
  controls. The session runtime is app-owned and survives closing the main window.
- Microphone capture via the `record` package.

### Local AI engine
- A single, runnable Rust engine (`notely-engine`) with graceful shutdown.
- **Two-pass analysis**: per-chunk extraction → synthesis → validation, with deterministic evidence
  grounding (each decision/action links to a transcript span; owners/deadlines are never invented).
- **LLM runtime** over Ollama, default `qwen3:1.7b` (configurable via `NOTELY_LLM_MODEL`).
- **Qwen3-ASR** speech-recognition provider on a separate HTTP runtime (behind an `AsrProvider`
  trait; Whisper is a stub for now).
- **FFmpeg** media probing/extraction for audio input.
- Deterministic **Markdown** and **JSON** renderers (no LLM used to format; HTML is a stub).
- An orchestrator with jobs, cancellation, and granular per-stage progress events.

### Infrastructure
- **Typed IPC** over loopback TCP with a versioned, language-neutral JSON-Schema contract
  (`packages/protocol`), request/response correlation, an async event stream, and client-side
  reconnect with backoff.
- **Local persistence** in SQLite (engine-side) plus plain files for notes.
- **CI** builds and tests the engine and the Flutter app, and compiles the desktop app on macOS,
  Windows, and Linux.
- Model **manifests** (metadata only — weights are never committed) with download/verify scripts.

### Not yet implemented
Called out honestly so nothing above is misread:
- System/call (loopback) audio capture — reported as `unsupported`; belongs in the engine later.
- Real ASR wired into the *live* listening flow (the engine's ASR path exists; the app currently
  drives summaries from transcript input, and uses a mock transcript during live listening).
- HTML export, Whisper ASR, and a system-tray relaunch + companion-position persistence on
  Windows/Linux. (Semantic/embedding search is future work; Ask uses full-text retrieval today.)

## Architecture

Notely is a monorepo with three layers and one boundary that matters.

```text
┌─────────────────────────────────────────────────────────────┐
│                    Flutter desktop app (apps/desktop)         │
│  workspace UI · file tree · editor · Ask · companion overlay  │
│  controllers (ChangeNotifier) → services → IPC client         │
└───────────────┬───────────────────────────┬─────────────────┘
                │                             │
     platform method/event channels          │  loopback TCP
                │                             │  (newline-delimited JSON,
                ▼                             │   versioned, request/response
┌───────────────────────────────┐            │   + async events)
│   Native OS runtimes           │            │
│   macOS Swift · Windows C++    │            ▼
│   Linux GTK/C++                │   ┌───────────────────────────────┐
│   detection · notifications ·  │   │        Rust engine (engine)   │
│   floating companion window    │   │  one package, internally      │
└───────────────────────────────┘   │  modular:                     │
                                     │  ipc · pipeline · media · asr │
                                     │  preprocess · ai · llm ·      │
                                     │  renderer · storage · domain  │
                                     └───────────────┬───────────────┘
                                                     │
                                                     ▼
                                        SQLite + on-disk artifacts
                                        (local app-data dir)
```

**Why this shape?**

- **Flutter (`apps/desktop`)** owns all UI, navigation, and interaction. It talks to the engine
  *only* over IPC and reaches the OS *only* through native service interfaces. It contains no
  media/ASR/AI/model/orchestration logic.
- **Native runtimes** provide the OS-specific pieces the UI can't (mic-activity detection, real
  notifications, an always-on-top overlay). They sit behind Dart interfaces and degrade to no-ops
  where a platform lacks support.
- **The Rust engine (`engine`)** is the single local backend — one Cargo package, internally
  modular by design (not microservices, not many crates) — owning everything below the IPC line.
- **IPC is the contract.** Because the boundary is typed and versioned, the frontend and engine are
  independently evolvable, and behavior can be made consistent across the three desktop OSes.

Design docs: [`docs/architecture.md`](docs/architecture.md),
[`docs/cross-platform.md`](docs/cross-platform.md), [`docs/ai-engine.md`](docs/ai-engine.md).

## How it works

### The IPC boundary

Flutter ↔ Rust communicate over a small, **versioned** protocol whose canonical definition is a
JSON Schema in [`packages/protocol/schema/ipc.schema.json`](packages/protocol/schema/ipc.schema.json).
The Rust server and the Dart client each mirror it.

- **Transport:** newline-delimited JSON over loopback TCP, default `127.0.0.1:8765` (override with
  `NOTELY_IPC_ADDR`). The transport is deliberately isolated so it can change later without
  rewriting the pipeline.
- **Correlation:** each request carries a `protocol_version` and a `request_id`; the matching
  response echoes the `request_id`. Events are pushed unsolicited on a broadcast stream (no
  `request_id`).
- **Requests:** `Health`, `ProcessMeeting`, `GetJob`, `CancelJob`, `GetMeeting`, `GetTranscript`,
  `GetMom`.
- **Events:** the full job lifecycle and per-stage progress — `JobCreated`, `TranscriptionStarted/
  Progress/Completed`, `ChunkingStarted/Completed`, `ExtractionStarted/Progress/Completed`,
  `SynthesisStarted/Completed`, `ValidationStarted/Completed`, `RenderingStarted/Completed`,
  `JobCompleted`, `JobFailed`.
- **Lifecycle:** the app owns a single connection, handshakes with `Health` (which also checks the
  protocol version), and **reconnects automatically** with capped exponential backoff. When the
  engine is unavailable the app **degrades gracefully** to offline mocks rather than failing.
- **Ownership:** a protocol-version *mismatch* is refused explicitly; malformed input yields an
  error response rather than dropping the connection.

Details: [`docs/ipc.md`](docs/ipc.md) · contract:
[`packages/protocol/README.md`](packages/protocol/README.md).

### The AI pipeline (engine)

```text
audio ──FFmpeg──▶ Qwen3-ASR ──▶ transcript
                                    │
transcript ─────────────────────────┘
   │
   ▼ deterministic Rust chunking/normalization (no LLM)
   ▼ per-chunk extraction (LLM, schema-constrained) ──▶ findings + provenance
   ▼ synthesis (LLM) ──▶ Meeting IR
   ▼ deterministic validation (no LLM)
   ▼ deterministic Rust renderer ──▶ Markdown / JSON
```

Two models on **two runtimes**, with deterministic Rust in between:

- **Qwen3-ASR** for speech recognition runs on a **separate ASR runtime** (HTTP) — *not* Ollama.
- **Qwen3 1.7B** for meeting understanding runs on **Ollama**.
- **Rust** owns chunking, evidence grounding, validation, and rendering.

Extraction and synthesis are **two separate LLM passes** (never a single "transcript → LLM → MOM"
call), coordinated through abstractions (`AsrProvider`, LLM runtime, renderer) rather than hard-wired
to a backend. See [`docs/pipeline.md`](docs/pipeline.md).

### The Meeting IR

The **Meeting IR** is the heart of the analysis: the LLM outputs **structured, validated,
evidence-linked data**, not final Markdown, and a deterministic renderer produces the MOM. This
gives traceability (every decision/action links to a transcript span), determinism, reuse, and
validation. Rationale: [`docs/meeting-ir.md`](docs/meeting-ir.md).

### Persistence

- **Notes** are plain Markdown files in the stash folder you choose — read/written directly by the
  app; app preferences (recent stashes, theme, Ask history) live in `shared_preferences`.
- **Meeting data** lives in the engine, not the app: a single local **SQLite** database
  (`rusqlite`, bundled) plus per-meeting artifacts (transcript, Meeting IR, rendered MOM). It is
  scoped **per user** under the OS app-data directory (override with `NOTELY_DATA_DIR`), created
  on demand (idempotent `CREATE TABLE IF NOT EXISTS`; no migration framework yet). The Flutter app
  never touches this database directly — it goes through IPC.

Storage design: [`docs/storage.md`](docs/storage.md).

## Platform support

One Flutter UI targets all three desktop OSes. Native meeting-companion behavior is implemented on
each, but runtime verification differs — stated honestly:

| Platform | Status | Notes |
|---|---|---|
| **macOS** | Reference platform; runtime-verified | Full native runtime (CoreAudio mic detection, `UNUserNotificationCenter`, floating `NSPanel` overlay + 2nd Flutter engine, background runtime). Notification delivery needs a signed build. |
| **Windows** | Implemented; **compile-gated in CI** | Native runtime (WASAPI capture detection, WinRT toasts, top-most tool-window overlay). Not yet runtime-tested; the companion is **opaque** (Flutter Windows embedder limitation). Needs on-device QA. |
| **Linux (X11)** | Implemented; **compile-gated in CI** | Native runtime (PulseAudio/PipeWire `pactl` detection, `GNotification`, keep-above transparent GTK overlay). Not yet runtime-tested. |
| **Linux (Wayland)** | Partial | Detection and notifications apply, but Wayland restricts always-on-top and absolute positioning, so overlay placement is limited. |

Platform capabilities are modeled explicitly (`PlatformCapabilities`, sourced from each OS's native
handler): the meeting runtime stays inert where detection is unsupported and skips the overlay where
it isn't available, instead of pretending. Cross-platform conventions:
[`docs/cross-platform.md`](docs/cross-platform.md) · companion design:
[`docs/meeting-companion.md`](docs/meeting-companion.md).

> Note: system/call (loopback) audio is **not** captured on any platform yet — it's reported as
> `unsupported` rather than silently failing.

## Getting started

You can run the **desktop app alone** (notes, file tree, editor, Ask) with just Flutter. The **AI
meeting features** additionally need the Rust engine and local model runtimes.

### Prerequisites

- **Flutter** (stable) with desktop support enabled, Dart SDK **≥ 3.12** (see
  `apps/desktop/pubspec.yaml`).
- **Rust** (stable, via `rustup`) with `rustfmt` + `clippy` (see `rust-toolchain.toml`) — only if
  you want the engine.
- Optional, for real meeting processing: **Ollama** (LLM runtime), a **Qwen3-ASR** runtime, and
  **FFmpeg** (audio input).
- Optional: **just** or **make** (otherwise call the scripts directly).

### Clone and bootstrap

```bash
git clone https://github.com/notely-ai/notely.ai
cd notely.ai
./scripts/bootstrap.sh      # verify toolchains, fetch Rust + Flutter deps
```

### Run just the app (no engine, no models)

```bash
./scripts/start-desktop.sh  # cd apps/desktop && flutter run
```

You'll get the stash picker, file tree, editor, and Ask over your notes. Meeting summaries will
fall back to an offline mock when no engine is connected.

### Run the full stack (app + engine)

```bash
# one-time: pull the LLM into Ollama's store (weights are never committed)
./scripts/download-models.sh   # ollama pull qwen3:1.7b
./scripts/verify-models.sh     # check Ollama/ASR runtimes are reachable

./scripts/dev.sh               # start the engine, then run the desktop app
```

Or run the two halves separately:

```bash
./scripts/start-engine.sh      # cargo run -p notely-engine
./scripts/start-desktop.sh     # flutter run
```

### Everyday commands

```bash
./scripts/check.sh   # cargo fmt --check + clippy (-D warnings); dart format + flutter analyze
./scripts/test.sh    # cargo test + flutter test
./scripts/build.sh   # release build of engine + desktop app for the host platform
```

Equivalent `make <target>` and `just <target>` recipes exist for each script (`make help` /
`just --list`). Configuration is environment-driven — copy `.env.example` and see
[`docs/development.md`](docs/development.md). Weights are never committed; manifests live in
`models/manifests/` (see [`models/README.md`](models/README.md)).

## Repository structure

```text
notely.ai/
├── apps/desktop/            Flutter desktop app
│   ├── lib/app/             root widget, theme, DI scope (AppScope)
│   ├── lib/features/        screens & state machines (stash, explorer, editor,
│   │                          listening, ask, meetings, workspace)
│   ├── lib/services/        business logic (filesystem, audio, meetings,
│   │                          notifications, companion, platform capabilities…)
│   ├── lib/ipc/             engine client + protocol (Dart mirror of the contract)
│   ├── lib/companion/       second Flutter entrypoint for the overlay window
│   ├── lib/platform/        presentation-time platform helpers
│   ├── macos/ windows/ linux/  native runtimes (detection, notifications, overlay)
│   └── test/ integration_test/
├── engine/                  Rust engine — ONE package, internally modular
│   └── src/{ipc,domain,pipeline,media,asr,preprocess,ai,llm,storage,renderer}/
├── packages/protocol/       canonical IPC contract (JSON Schema, no logic)
├── models/manifests/        model METADATA only — never weights
├── data/fixtures/           small sample transcripts / meeting_ir / audio
├── docs/                    flat documentation (architecture, ipc, pipeline, …)
├── scripts/                 flat dev scripts (bootstrap, dev, check, test, build, …)
├── tests/                   cross-cutting integration + evaluation scaffolding
└── Cargo.toml · Makefile · justfile · rust-toolchain.toml · .env.example
```

`docs/` and `scripts/` are intentionally **flat**; the Rust side is intentionally **one package**.

Where to start reading:
- **App behavior / UI:** `apps/desktop/lib/features/` and `apps/desktop/lib/app/app.dart`.
- **App ↔ engine wire:** `apps/desktop/lib/ipc/` and `packages/protocol/`.
- **Meeting lifecycle:** `apps/desktop/lib/features/meetings/` (the app-owned session manager) and
  the per-OS `apps/desktop/{macos,windows,linux}/…/notely_runtime.*`.
- **AI pipeline:** `engine/src/pipeline/`, `engine/src/ai/`, `engine/src/domain/`.

## Development model

The boundaries tell you where a change belongs:

```text
UI / interaction        → Flutter (apps/desktop/lib)
OS-specific behavior     → native runtimes + a Dart service interface
Application behavior/AI   → Rust engine (engine/src)
Cross-boundary change    → the IPC contract first (packages/protocol)
Persistence semantics    → engine storage (SQLite) or the app's file/prefs layer
```

Practically:

- Changing how something is **presented or edited**? Start in the Flutter app.
- Changing **application behavior, analysis, or meeting persistence**? Work in the engine.
- Adding **OS-specific capability** (detection, notifications, overlay)? Implement the native
  runtime behind the existing Dart interface, and report it through `PlatformCapabilities` so the
  app degrades honestly elsewhere.
- Change **crosses the UI/engine boundary**? Update the IPC contract first — that means all three of
  `packages/protocol`, the Rust `ipc` side, and the Dart `ipc` side — and bump the protocol version.

## Contributing

Contribution guidelines are still evolving — for now, please **open an issue before undertaking
large architectural changes**. Beyond that, keep changes small and aligned with the boundaries
above:

- One Rust engine, internally modular — don't split it into crates.
- `docs/` and `scripts/` stay flat.
- Flutter never depends on engine internals — only on the IPC contract.
- Pure UI widgets don't import `dart:io` or branch on `Platform.isX`; OS knowledge lives behind
  services (see [`docs/cross-platform.md`](docs/cross-platform.md)).
- IPC changes touch **all three** protocol surfaces and bump the version (see
  [Development model](#development-model)).
- Run `./scripts/check.sh` and `./scripts/test.sh` before opening a PR — CI runs the same checks
  plus a desktop build on macOS, Windows, and Linux.

Good first areas: wiring real ASR into the live listening flow, the HTML renderer, semantic
(embedding) search to complement Ask's full-text retrieval, and on-device QA / hardening for the
Windows and Linux native runtimes.

## Roadmap

Directions, not commitments — see the decision log ([`docs/decisions.md`](docs/decisions.md)) and
open questions ([`docs/research.md`](docs/research.md)) for the reasoning.

- **Current:** local Markdown workspace; source-grounded Ask (engine-side FTS5 retrieval + local
  LLM, with citations and offline fallback); Inbox with durable capture states + one-click retry
  (source persisted before AI, so AI failure never loses data); meeting detection + notification +
  overlay (macOS verified); local two-pass AI pipeline (transcript → Meeting IR → Markdown) proven
  end-to-end.
- **Near-term:** runtime-verify and harden the Windows/Linux native runtimes (incl. tray relaunch
  and companion-position persistence); wire real ASR into live listening; semantic (embedding)
  search alongside Ask's full-text retrieval; HTML export.
- **Longer-term:** system/call audio capture; richer intelligence (diarization, a verification
  pass, long-meeting handling); and optional — never required — cloud adapters and integrations.

## License

**MIT**, as declared in `Cargo.toml` (`license = "MIT"`). There is currently **no dedicated
`LICENSE` file** at the repo root; adding one is a welcome first contribution. Until then, this
section is the reference.

## Security

Notely is local-first: your notes and meeting data stay on your machine, and nothing is required to
leave it. Please report security concerns privately via a GitHub security advisory rather than a
public issue.
