# Decisions

A lightweight log of the major v0 architectural decisions. Newest first. Keep entries short:
what we decided, and why.

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
