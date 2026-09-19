# engine/src/storage — persistence & data safety

Owns all local persistence behind the **`Store` trait** (`repositories/mod.rs`; backend in
`database.rs`). Callers use domain types; nothing above `storage/` knows it's SQLite.

## Canonical sources of truth (the point of this module)
- **`notely.db` — authoritative.** Meetings + artifacts keyed by `(meeting_id, kind)`:
  `transcript`, `meeting_ir`, `mom`, `processing_status`. A **new artifact kind needs no schema change** —
  prefer a new `kind` over new columns.
- **Derived, rebuildable — never a source of truth:** `search.db` (FTS5 + optional embeddings, owned by
  `search/`), `jobs.db` (job queue, owned by `pipeline/job_store.rs`), `llm_cache.db` (LLM cache, owned
  by `llm/cache.rs`). Losing any of them only costs a rebuild.
- The **Markdown vault** on disk is separate user-facing data (Search/Ask/Knowledge Space derive from it).

## Data-safety invariants (do not break)
- **Source before AI:** the meeting + transcript are saved *before* any AI runs, and
  `processing_status` (`processing`/`ready`/`deferred`/`failed`) is a **separate artifact**. So an AI/LLM
  failure marks enrichment `deferred` (retryable) — it never loses the capture.
- **Domain in, domain out.** Repositories load/save `domain` types; no SQL leaks upward.
- **Local-first.** No network dependency; data lives in `NOTELY_DATA_DIR` (OS app-data dir), outside the
  repo (`scripts/reset-data.sh` resets it).
- Blocking SQLite calls run on Tokio's blocking pool.

## Schema / migration rules
- Additive first (new `kind` / optional field). Old stored IR/status must still deserialize
  (`status == None` ⇒ treat as `Ready`).
- **`notely.db` changes need a real migration + back-compat**; derived DBs should be **rebuilt**, not
  migrated in place.

## Testing
`engine/tests/reliability.rs` (source-before-AI, deferred/recovery), `domain_serde.rs` (old-data
deserialization). Add a pre-migration fixture test for any source-of-truth format change.

## Related skills
storage · schema-evolution · migration · backwards-compatibility · crash-recovery · large-vault · testing

## Related modules
`engine/CLAUDE.md` · search (`search/`, derived index) · `pipeline/job_store.rs` (jobs.db)
