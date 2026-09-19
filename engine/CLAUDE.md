# engine — Rust backend

The single local backend: one Cargo package `notely-engine` (lib `notely_engine` + thin `main.rs`),
internally modular. It owns **everything below the IPC line** and is reached only over IPC.

## Responsibilities (module map, `src/`)
| Module | Owns | Must not know about |
|---|---|---|
| `domain/` | Portable types (Meeting, Transcript, MeetingIr, ProcessingStatus, Citation, …) | anything else |
| `ipc/` | Flutter↔Rust boundary: requests/responses/events, versioning, transport | pipeline internals |
| `pipeline/` | Stage ordering + jobs/events + cancellation + startup recovery | provider specifics |
| `media/` | FFmpeg audio normalize + VAD boundary | Flutter |
| `asr/` | `AsrProvider` (Qwen3-ASR default / Whisper / fixture) | Flutter |
| `preprocess/` | Deterministic transcript normalize + chunking | LLMs |
| `ai/` | Two-pass semantic analysis over domain types (extraction/synthesis/validation) | which runtime serves the model |
| `llm/` | `LlmProvider` (generate/health/embed) + Ollama/MLX + result cache | meeting semantics |
| `search/` | Vault FTS5 (+ optional embeddings) retrieval + grounded Ask | Flutter |
| `sources/` | Slack/Teams import into the vault (→ `src/sources/CLAUDE.md`) | Flutter |
| `storage/` | Local persistence behind repository traits (→ `src/storage/CLAUDE.md`) | Flutter |
| `renderer/` | Deterministic IR → Markdown/HTML/JSON | LLMs |

## Does not own
Any UI, navigation, or window/overlay logic (that's `apps/desktop/`). It never renders widgets and
never assumes a specific frontend — the engine is reusable behind IPC.

## Boundaries (don't bypass)
- Everything in/out crosses **IPC** (`ipc/`); see `packages/protocol/CLAUDE.md`.
- The pipeline depends on **traits/helpers**, never concrete backends: `AsrProvider`, `AiAnalyzer`,
  `LlmProvider`, `Store`, `preprocess::prepare`, `renderer::markdown`. Add a backend = new trait impl.
- `ai/` asks `llm/` for *meaning*; it never speaks HTTP to Ollama. Runtimes (Ollama/MLX/ASR) are
  **separate local servers over HTTP** — never linked into this process.

## Canonical sources of truth
- `notely.db` — meetings + artifacts by `(meeting_id, kind)`. **Authoritative.**
- `search.db` / `jobs.db` / `llm_cache.db` — **derived, rebuildable**; never treat as source of truth.
- `ai/schema.rs` owns the JSON schemas the model fills in (the model does not define them).

## Important invariants
- **Source saved before AI runs**; `processing_status` is a separate artifact → AI failure never loses
  the capture (marks it `deferred`, retryable).
- **Two separate LLM passes** (extraction per chunk → synthesis); never collapse to one call.
- **Provenance/anti-invention is deterministic Rust**: evidence grounding, owner/deadline guard,
  participant backfill (`ai/extraction.rs`, `ai/synthesis.rs`).
- **Cancellation is cooperative** (`CancelFlag` checked between stages and chunks); cancelled work is
  retryable, resources released.
- Errors are typed per-module enums (`thiserror`) and **degrade honestly** — unreachable runtime,
  missing FFmpeg → clean error/deferral, never a crash or a silent stub.

## Local conventions
- Gates: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings` (warnings are errors),
  `cargo test`. Every file opens with a doc comment explaining the *seam*, not the code.
- Async: Tokio; blocking SQLite on the blocking pool. Config is env vars (`config.rs`), not a framework.

## Important files
`ipc/protocol.rs` · `ipc/server.rs` · `pipeline/orchestrator.rs` · `pipeline/jobs.rs` ·
`ai/provider.rs` · `ai/schema.rs` · `llm/provider.rs` · `storage/repositories/mod.rs` ·
`search/index.rs` · `domain/meeting_ir.rs` · `config.rs`.

## Testing
`engine/tests/` — `domain_serde`, `transcript_prep`, `ai_pipeline` (fixture provider), `pipeline_order`,
`reliability` (source-before-AI/recovery), `search_index`, `ipc_roundtrip`. Real-model path is
`ollama_smoke.rs` (**`#[ignore]` by default — keep it out of the default suite**). Use fixtures /
`fixture` providers; tests must not require a live Ollama/ASR/MLX.

## Generated / out-of-repo — do not hand-edit
`Cargo.lock` (update via cargo); model **weights** (fetched); the app-data DBs (`notely.db` etc.) live
in `NOTELY_DATA_DIR`, not the tree.

## Related skills
architecture · ai-runtime · ollama · apple-silicon · cuda · extraction · synthesis · meeting-ir ·
ingestion · concurrency · crash-recovery · resource-lifecycle · failure-modes · testing

## Related modules
`apps/desktop/CLAUDE.md` (frontend) · `packages/protocol/CLAUDE.md` (IPC contract) ·
`engine/src/storage/CLAUDE.md` · `engine/src/sources/CLAUDE.md`
