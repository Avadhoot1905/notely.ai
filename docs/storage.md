# Storage

Notely is **local-first**: meeting data stays on the user's machine by default. Storage lives
entirely in `engine/src/storage/` and is never exposed to Flutter — the app sees domain data over
IPC, never database internals.

## Strategy (v0)

Start simple and inspectable, and don't lock into an elaborate schema prematurely.

- The engine persists, per meeting: **metadata**, **transcript**, **Meeting IR**, the
  **rendered MOM**, and a **processing status** (`processing`/`ready`/`deferred`/`failed`).
- Crucially, the **source** (meeting + transcript) is saved *before* any AI runs, and the
  processing status is a separate artifact. So an AI/LLM failure never loses the capture — it just
  marks enrichment `deferred` (retryable). This is the storage-level half of "AI failure ≠ data
  loss" (see [pipeline.md](pipeline.md)).
- A lightweight embedded database (SQLite) holds meetings + artifacts keyed by `(meeting_id, kind)`
  (`transcript`, `meeting_ir`, `mom`, `processing_status`), so new artifact kinds need no schema
  change (the source of truth, `notely.db`).
- All of this is confined behind the **`Store` trait** (`storage/repositories/`). Callers use the
  trait; the backend is an implementation detail.

### Derived, rebuildable databases (source-of-truth is never at risk)

Three small SQLite files hold **derived** data — losing any of them only costs a rebuild, so they
live outside the meeting store:

- **`search.db`** — the vault index. An FTS5 table over Markdown notes (lexical search) plus an
  optional `embeddings` table (dense vectors for hybrid search). Both are kept in sync incrementally
  by file fingerprint `(mtime, size)`; embeddings are (re)computed asynchronously and only for
  changed notes. Hybrid search is opt-in (`NOTELY_LLM_MODEL_EMBEDDING`); without it, `search.db` is
  FTS5-only exactly as before. See [pipeline.md](pipeline.md).
- **`jobs.db`** — the persistent job queue. Every job and state transition is mirrored here so
  background work (enrichment, embedding) survives a crash/restart; the engine requeues anything
  left `queued`/`running` on startup, bounded by a small retry budget. This is operational metadata,
  not a distributed queue.
- **`llm_cache.db`** — the transparent LLM result cache (see [ai-engine.md](ai-engine.md)). Pure
  speed-up; safe to delete.

A conceptual on-disk layout for a meeting's artifacts:

```text
<app-data-dir>/meetings/2026-09-12-product-planning/
├── audio.wav
├── transcript.json
├── meeting_ir.json
└── mom.md
```

Data lives in an OS-appropriate application-data directory **outside the repo** (see
`scripts/reset-data.sh`), never in the working tree.

## Principles

- **Hide the backend.** Nothing above `storage/` knows whether it's SQLite, files, or both.
- **Domain in, domain out.** Repositories load/save `domain` types.
- **Local-first.** No network dependency; cloud sync, if ever added, is an optional adapter.
- **Don't over-build.** Add indexing/search/sync when a feature actually needs it — see the open
  question "when is a database actually necessary?" in [research.md](research.md).
