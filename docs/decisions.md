# Decisions

A lightweight log of the major v0 architectural decisions. Newest first. Keep entries short:
what we decided, and why.

## D-0016 — Deterministic evidence grounding in Rust
Small models unreliably copy quotes, so Rust matches each extracted item back to its source
transcript segment and attaches the real quote + timestamps + speaker + `chunk_id`
(`ai/extraction.rs`). Owners/deadlines the synthesis model can't support from findings or the
transcript are dropped to null. Provenance and anti-invention are Rust's job, not the model's.

## D-0015 — Two separate LLM passes (extraction → synthesis)
Extraction runs once per chunk → `ChunkFindings`; synthesis consolidates them → Meeting IR. Never
`transcript → LLM → MOM`. Buys long-meeting scalability, provenance, debuggability, and lets
chunking change independently of prompts. See [ai-engine.md](ai-engine.md).

## D-0014 — Deterministic transcript preprocessing/chunking is Rust, not the LLM
Normalization (whitespace/order/timestamps) and segment-aware chunking live in `preprocess/`. The
raw ASR transcript is preserved separately from the normalized copy. The LLM never does mechanical
chunking.

## D-0013 — ASR is a SEPARATE runtime from the LLM
Qwen3-ASR is the default ASR, served by its own HTTP runtime (`asr/qwen3_asr.rs`) — NOT Ollama,
which can't do speech-to-text. The LLM (Qwen3 1.7B) stays on Ollama. Whisper is an optional
provider behind the same `AsrProvider` trait. Model and runtime are configured independently.

## D-0012 — Default LLM is Qwen3 1.7B (down from 4B)
The small `qwen3:1.7b` is the v0 default for meeting understanding — fast on a dev laptop and good
enough with the two-pass + deterministic-grounding design. Configurable via `NOTELY_LLM_MODEL`
(`qwen3:0.6b`/`qwen3:4b`) without touching the pipeline.

## D-0011 — IPC transport: newline-delimited JSON over loopback TCP
The v0 transport is line-framed JSON on `127.0.0.1:8765`, isolated in `engine/src/ipc/server.rs`.
Simple, cross-platform, trivially testable, and swappable later. Not an HTTP/web server — just
framing — honoring the "no web server for IPC" constraint.

## D-0010 — Engine is a library + thin binary
`engine` exposes a `notely_engine` lib (all modules) plus a small `main.rs`. This makes modules
unit- and integration-testable (`engine/tests/`) without splitting into multiple crates.

## D-0009 — SQLite (rusqlite, bundled) is the v0 store
Embedded, file-based, no server. Bundled build ⇒ no system SQLite dependency. Blocking calls run
on Tokio's blocking pool. Artifacts (transcript/IR/MOM) are stored by `(meeting_id, kind)` so new
artifact kinds need no schema change. See [storage.md](storage.md).

## D-0008 — Development model: `qwen3:4b` via Ollama
Default LLM is Qwen3 4B (Q4_K_M, ~2.5 GB) — fits a dev laptop while producing usable Meeting IR.
Model-agnostic: override with `NOTELY_OLLAMA_MODEL`. See `models/manifests/qwen3.yaml`.

## D-0007 — Structured output via schema-constrained generation
The AI layer sends the IR JSON Schema as Ollama's `format` and deserializes/validates the result;
malformed output errors out. The Rust side owns the schema — the model fills it in. See
[ai-engine.md](ai-engine.md).

## D-0006 — Local-first storage, backend hidden behind repositories
Data stays on the user's machine; storage lives in `engine/src/storage` behind repository traits.
Start simple (likely SQLite + files), don't over-design. Flutter never sees DB internals.
See [storage.md](storage.md).

## D-0005 — Meeting IR is the contract; rendering is deterministic
The LLM outputs a structured [Meeting IR](meeting-ir.md), not the final MOM. A deterministic,
template-based renderer produces Markdown/HTML/JSON. No LLM is used merely to format. This buys
traceability (evidence spans), reuse, and validation.

## D-0004 — Clean AI / runtime / model boundaries
`ai` performs semantic operations over domain types; `llm` owns the runtime behind `LlmProvider`
(Ollama first); models are described by manifests with weights kept out of the repo. The AI layer
never knows which runtime serves the model. See [ai-engine.md](ai-engine.md).

## D-0003 — Provider abstractions, not hard-wired backends
The pipeline depends on traits — `AsrProvider` (Whisper impl), `AiProvider`, `LlmProvider` — so
backends can be swapped without touching orchestration.

## D-0002 — IPC is the single backend boundary
Flutter ↔ Rust communicate over a small, versioned, serializable protocol. The transport is
isolated so it can change without rewriting the pipeline. No web server, no cloud backend.
See [ipc.md](ipc.md).

## D-0001 — One Rust engine, one Flutter app
For v0 there is exactly **one** Rust package (`engine`, internally modular) and **one** desktop
Flutter app (`apps/desktop`). No microservices, no premature crate-splitting. The root Cargo
workspace is ready for future growth without forcing it. `docs/` and `scripts/` stay flat.

## D-0000 — Pivot from CLI/Tauri concept to Flutter + Rust
The earlier concept explored a CLI-first tool with a possible Tauri+React UI. v0 commits to a
Flutter desktop app over a Rust engine via IPC. The engine remains reusable by other frontends
later.
