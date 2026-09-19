---
name: search
description: Load when working on vault Search/Ask — the FTS5 index, optional embeddings (hybrid via reciprocal rank fusion), incremental sync by file fingerprint, background embedding jobs, and how retrieval degrades. Search runs off the Markdown vault, not the meeting DB.
---

# search

## What search indexes
Search runs off the **user's Markdown vault** on disk (`vault_path`), separate from the meeting
pipeline. The index is `search.db` (`engine/src/search/`) — **derived and rebuildable**.

## Structure (`search/index.rs`)
- **FTS5 table** over notes (lexical). A `Passage { path, start_line, end_line, body, … }` is the unit;
  `SearchHit` is derived from it (body trimmed to a snippet). `search/chunker.rs` splits notes into
  passages; snippets come from `chunker::snippet`.
- **Optional `embeddings` table** — dense vectors as SQLite BLOBs with brute-force cosine (no native
  extension; sufficient for a personal vault — D-0019).

## Incremental sync + background embedding
- On vault sync, FTS5 updates **immediately**; sync touches only changed notes, detected by file
  fingerprint `(mtime, size)` (`SyncStats`).
- If hybrid is enabled (`NOTELY_LLM_MODEL_EMBEDDING` set), embedding of changed notes runs as a
  **background, persisted `Embedding` job** so it never blocks note saving or search results. "What
  needs embedding" is derived from a fingerprint mismatch → interrupted embedding is self-healing
  (the next search resumes it). See concurrency, crash-recovery.

## Retrieval + ranking
Hybrid retrieval fuses FTS5 + vector results via **reciprocal rank fusion**, falling back to
**FTS5-only** whenever embeddings are unavailable (no model configured, or embedding not yet done).
So search always works offline; hybrid is a quality bonus (offline-first).

## Ask (QA) and Knowledge Space
`Ask` retrieves passages then answers *strictly from what it retrieves* — see citations.
`GetKnowledgeMap` derives the **Knowledge Space** from the *same* index, so it costs nothing extra and
stays in step with Search/Ask (`knowledge_map/`).

## Consistency / deletion
The index mirrors the vault: deleted/renamed notes are reconciled on sync by fingerprint. Losing
`search.db` is safe — it rebuilds from the vault. Don't treat it as a source of truth.

## Tests
`engine/tests/search_index.rs`; Flutter `apps/desktop/test/ask/`, `knowledge/`.

## Related skills
citations · storage · large-vault · ai-runtime · offline-first · knowledge (knowledge-map) · testing
