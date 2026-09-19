# engine/src/sources — external knowledge sources (security boundary)

Imports **Slack/Teams** content into the vault. This is the one module with routine **outbound network
egress** and **user tokens**, so treat it as a security/privacy boundary.

## What it owns
- `list_channels` / `import` / `list_sources` / `disconnect` behind the `Ingestor` + per-source
  providers (`slack.rs`, `teams.rs`, `registry.rs`, `provider.rs`, `model.rs`).
- Normalizing imported messages into **provenance-bearing Markdown notes** under `Imported/<Source>/`
  (`IMPORT_ROOT = "Imported"`), so they flow through the *same* index → Search → Ask → citation path.

## Non-negotiable invariants
- **Tokens are passed in-memory per request and NEVER persisted** by the engine. Only non-secret
  bookkeeping (what's connected/imported) is stored. **Never log, cache, or write a token to disk.**
- **Slack/Teams structures never leak past this module** — the rest of Notely sees only vault Markdown
  or generic source types.
- **Import is idempotent** — re-importing a channel updates notes without duplicating.
- Network failures return typed `SourceError`; a missing/invalid token fails cleanly (token still never
  persisted). Bounded parsing of untrusted remote content.

## Does not own
Search/indexing (that's `search/`, which picks up the `Imported/` notes on the next vault sync) or the
UI connect/import flow (`apps/desktop/lib/features/integrations/`).

## Testing
In-module tests use a `MockTransport` (no live network) and assert idempotent import into a temp vault +
that imported notes become searchable. Keep new source logic testable without real Slack/Teams.

## Related skills
security · privacy · threat-modeling · offline-first · search · testing

## Related modules
`engine/CLAUDE.md` · search (`search/`) · storage (`engine/src/storage/CLAUDE.md`)
