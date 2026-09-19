---
name: schema-evolution
description: Load when evolving any Notely schema — Meeting IR, SQLite tables, IPC messages, serialized processing state, Markdown metadata, or config. Explains what is additive-safe vs breaking, and how each store handles change.
---

# schema-evolution

## The schemas and how they evolve
- **Meeting IR** (`domain/meeting_ir.rs`, mirrored in `ai/schema.rs`) — intentionally small in v0;
  designed to *grow* (topics, questions, risks, timeline). Adding optional fields is safe; the
  renderer (`renderer/markdown.rs`) keys off field order and skips empty sections. Keep new fields
  optional/defaulted so old stored IR still deserializes.
- **SQLite meeting store** (`notely.db`) — artifacts keyed by `(meeting_id, kind)` precisely so a
  **new artifact kind needs no schema change** (D-0009). Prefer a new `kind` over new columns.
- **IPC messages** — versioned; see api-contracts and backwards-compatibility. Breaking change ⇒
  three-places update + `PROTOCOL_VERSION` bump. Prefer additive (new request/response variant).
- **Processing status** (`domain/processing.rs`) — serde enum (`processing`/`ready`/`deferred`/
  `failed`); `MeetingSummary.status` is `Option`, and `None` (pre-status meetings) is treated as
  already `Ready`. Preserve that "absent = ready" back-compat when extending.
- **Search index** (`search.db`) — derived/rebuildable; schema changes are cheap because the index
  re-syncs from Markdown by file fingerprint. Bump/rebuild instead of migrating in place.
- **Markdown vault + metadata** — the notes on disk are user data / partly source of truth for
  imported content; provenance front-matter written by `sources/` must stay parseable.
- **Config** (`config.rs` / env vars) — additive; keep old names working (e.g. `NOTELY_OLLAMA_MODEL`
  is kept as a legacy alias for `NOTELY_LLM_MODEL`). Unset = prior behavior.

## Rules
1. **Additive over breaking.** New optional field / new artifact `kind` / new message variant first.
2. **Old data must still load.** Test deserialization of previously-written IR/status/config.
3. **Source of truth (`notely.db`) needs a real migration + back-compat**; derived DBs can be rebuilt.
4. **Version the boundary, not the internals** — bump `PROTOCOL_VERSION` for IPC; internal Rust
   struct changes don't need a version unless they're persisted.

## Related skills
backwards-compatibility · migration · api-contracts · storage · meeting-ir · testing
