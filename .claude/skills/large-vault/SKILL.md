---
name: large-vault
description: Load when reasoning about scale — how Notely behaves as the vault grows from 100 to 100k+ notes/meetings. Focuses on startup, indexing, search, memory, SQLite, filesystem, and UI. Grounds scale reasoning in the actual design; avoid inventing numeric budgets.
---

# large-vault

## What actually scales with vault size
- **Indexing** (`search.db`): incremental by file fingerprint `(mtime, size)` — only *changed* notes
  are re-indexed, so steady-state cost is proportional to edits, not vault size. First-time full index
  is O(vault). Embedding is a **background persisted job**, so it never blocks saves/search.
- **Search:** FTS5 is the fast path and always available. **Vector search is brute-force cosine over
  BLOBs** (D-0019) — fine for a *personal* vault, but it's linear in the number of embedded passages;
  this is the most likely scaling pressure point at very large vaults. FTS5-only fallback bounds it.
- **Meeting store** (`notely.db`): artifacts keyed by `(meeting_id, kind)`; `ListMeetings` scans
  meeting summaries — cost grows with meeting count. Watch it if the Inbox loads all summaries.
- **Startup:** engine startup requeues incomplete jobs from `jobs.db` (bounded by a retry budget) and
  opens the DBs; not proportional to vault size except for any pending re-index.
- **Filesystem:** the vault is many Markdown files; the watcher may fall back to a top-level watch on
  Linux (deep edits need a refresh — cross-platform doc). Reveal/list operations touch the FS directly.
- **UI:** Flutter renders lists (Inbox, explorer, search results); prefer lazy/virtualized rendering
  for large result sets. The overlay renders only snapshots, not the whole vault.

## Reasoning at scale (order-of-magnitude, not promises)
- ~100–1,000: everything is comfortably in-budget; no special handling.
- ~10,000: full re-index and brute-force vector search become noticeable — favor incremental sync and
  FTS5-first; consider capping vector candidates.
- ~100,000+: brute-force cosine and unbounded list rendering are the realistic bottlenecks — measure
  before optimizing (profiling); an ANN index would be a *future* change, not assumed today.

## Don't
Invent concrete latency/memory budgets — the repo defines few. Measure (profiling, performance-budget)
and state assumptions as observations (no-speculation). Don't turn a derived index into a source of truth.

## Related skills
search · storage · citations · performance-budget · profiling · flutter-ui
