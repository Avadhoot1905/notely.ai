---
name: migration
description: Load when migrating persisted data — SQLite databases, the Markdown vault, serialized IR/status, or config. Notely's split between one source-of-truth DB and derived rebuildable DBs makes most migrations cheap; this skill says which is which and how to do each safely.
---

# migration

## First question: source of truth or derived?
- **`notely.db` (source of truth)** — a schema/format change needs a **real migration + back-compat**:
  old stored `Meeting`/`Transcript`/`MeetingIr`/`ProcessingStatus` must still load. Because artifacts
  are keyed by `(meeting_id, kind)`, most additions are a **new kind, not a migration** (prefer that).
- **`search.db` / `jobs.db` / `llm_cache.db` (derived)** — **don't migrate; rebuild.** They regenerate
  from the vault / re-derive from the source. A format change can just bump/recreate the file. Losing
  them is safe by design (storage).

## Vault migrations (user's Markdown)
The vault is user data. **Never silently rewrite it.** Preserve line endings (LF/CRLF remembered) and
avoid case-only self-collisions (cross-platform doc). Imported-note front-matter (`sources/`) must stay
parseable; a format change there needs a re-import or a tolerant reader.

## Config migrations
Additive and tolerant: keep old env names working (legacy `NOTELY_OLLAMA_MODEL` alias); unset ⇒ prior
behavior. Don't require users to re-set existing config.

## Safe procedure
1. Detect the old version/shape; support reading it.
2. Migrate forward on load or via an explicit one-time step; **write the new form, keep the old
   readable** until the migration is proven.
3. Add a test that loads a **pre-migration fixture** and asserts correct upgrade (test-generation).
4. Idempotent + resumable: a crash mid-migration must not corrupt the source (crash-recovery).
5. For derived DBs, prefer "delete + rebuild" over in-place migration.

## Related skills
schema-evolution · backwards-compatibility · storage · crash-recovery · testing
