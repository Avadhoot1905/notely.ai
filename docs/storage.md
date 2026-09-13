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
  change. A separate, rebuildable `search.db` holds the FTS5 vault index.
- All of this is confined behind the **`Store` trait** (`storage/repositories/`). Callers use the
  trait; the backend is an implementation detail.

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
