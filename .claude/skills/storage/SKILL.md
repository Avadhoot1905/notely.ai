---
name: storage
description: Load when touching persistence — the SQLite meeting store (source of truth) vs derived rebuildable DBs, the Store trait, artifact-by-(meeting_id,kind) design, the Markdown vault, and the "source saved before AI" reliability guarantee.
---

# storage

## Sources of truth vs derived
- **`notely.db`** — the **source of truth**. Meetings + artifacts keyed by `(meeting_id, kind)`:
  `transcript`, `meeting_ir`, `mom`, `processing_status`. A **new artifact kind needs no schema
  change** (D-0009). Behind the `Store` trait (`storage/repositories/mod.rs`) — callers use domain
  types, never SQL.
- **Derived, rebuildable (losing them only costs a rebuild):**
  - `search.db` — FTS5 over vault Markdown + optional `embeddings` table (hybrid). See search.
  - `jobs.db` — persistent job queue for crash recovery (`pipeline/job_store.rs`). See crash-recovery.
  - `llm_cache.db` — transparent LLM result cache; safe to delete. See ai-runtime.
- **Markdown vault** — the user's notes on disk (+ `Imported/<Source>/` provenance notes). Search/Ask/
  Knowledge Space are all derived from this, not from `notely.db`.

## The reliability guarantee (storage half of "AI failure ≠ data loss")
The **source (meeting + transcript) is saved *before* any AI runs**, and `processing_status`
(`processing`/`ready`/`deferred`/`failed`) is a **separate artifact**. An AI/LLM failure marks
enrichment `deferred` (retryable) — it never loses the capture. Keep this ordering in any pipeline change.

## Principles
- **Hide the backend.** Nothing above `storage/` knows it's SQLite. Domain in, domain out.
- **Local-first.** No network dependency; cloud sync (if ever) is an optional adapter.
- Data lives in the OS app-data dir (`NOTELY_DATA_DIR`), **outside the repo** (`scripts/reset-data.sh`).
- Blocking SQLite runs on Tokio's blocking pool.

## `Store` trait surface
`save/get_meeting`, `list_meetings`, `save/get_transcript`, `save/get_meeting_ir`, `save/get_mom`,
`save/get_processing_status`. Errors: `StorageError::{Backend, Serde}`.

## Before changing schema
Source-of-truth changes need a migration + back-compat (old IR/status must load); derived DBs can be
rebuilt. See schema-evolution, migration, backwards-compatibility.

## Related skills
schema-evolution · migration · search · citations · large-vault · crash-recovery · backwards-compatibility
