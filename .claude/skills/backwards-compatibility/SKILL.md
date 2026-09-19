---
name: backwards-compatibility
description: Load before any change that could break existing installs — old vaults, old databases, old configs, prior IPC contracts, or established user workflows. Documents Notely's compatibility guarantees and how to preserve them.
---

# backwards-compatibility

## What existing users already have on disk
- A **Markdown vault** (their notes + `Imported/<Source>/` provenance notes).
- `notely.db` (meetings/transcripts/IR/MOM/status — the source of truth) and rebuildable
  `search.db`/`jobs.db`/`llm_cache.db` in the app-data dir.
- A `.env` / environment config; possibly older `NOTELY_OLLAMA_*` variable names.
- An installed app speaking a specific `PROTOCOL_VERSION`.

## Guarantees to preserve
- **Old stored IR / status must deserialize.** New IR fields optional; `status == None` means
  `Ready`. See schema-evolution.
- **Legacy config names keep working** (e.g. `NOTELY_OLLAMA_MODEL` → `NOTELY_LLM_MODEL`); unset ⇒
  prior behavior for every knob (per-task model overrides, embeddings-off, etc.).
- **The vault format stays readable.** Don't rewrite users' Markdown silently (line endings and
  case-only renames are explicitly preserved — see cross-platform doc). Imported-note front-matter
  must remain parseable by `sources/`.
- **IPC:** the client refuses a mismatched major version, so a protocol change requires shipping
  engine + app together and bumping the version. Prefer additive changes so mixed builds fail loud,
  not silently.

## Before a breaking change, ask
1. What existing on-disk artifact does this invalidate, and can I migrate it? (See migration.)
2. Can I make it additive instead (new field / `kind` / message variant / env var)?
3. If it must break, is there a version bump + a migration + a test loading old data?
4. Does it change a workflow users rely on (Inbox retry, offline Ask, reprocess idempotency)?

## Idempotency guarantees users rely on
`ReprocessMeeting` retries enrichment from the stored transcript **without re-capturing or
duplicating** (source saved before AI). Keep any new pipeline step idempotent w.r.t. retry/recovery.

## Related skills
schema-evolution · migration · api-contracts · storage · offline-first · crash-recovery
