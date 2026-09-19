---
name: change-impact
description: Load before implementing any change that crosses a module or contract, to map the blast radius first — affected components, contracts, persistence, UI, platforms, concurrency, security/privacy, tests, and docs. Prevents surprise breakage in Notely's two-component system.
---

# change-impact

## Purpose
Before writing code, enumerate what a change touches. Notely's boundaries mean a small edit can
ripple across the IPC line, three native platforms, and rebuildable databases.

## Checklist (fill in for the specific change)
- **Components:** engine only, Flutter only, or both? Anything crossing IPC touches *three* places
  (`packages/protocol`, Rust `ipc`, Dart `ipc`) and bumps `PROTOCOL_VERSION`. See api-contracts.
- **Contracts:** which trait/message/schema changes? `LlmProvider`, `AsrProvider`, `AiAnalyzer`,
  `Store`, IPC `Request`/`Response`/`Event`, `ai/schema.rs` JSON schemas, `MeetingIr` shape.
- **Persistence:** does it change `notely.db` (source of truth — needs migration + back-compat) or a
  derived DB (`search.db`/`jobs.db`/`llm_cache.db` — safe to rebuild)? See schema-evolution, migration.
- **UI:** which `features/*` controllers/widgets read the changed data? Does `EngineClient` need it?
- **Platforms:** any native code? A `notely/*` channel or payload key must change on **all four**
  implementations (macOS/Windows/Linux + Dart). Any `dart:io`/`Platform.isX` must stay behind a service.
- **Concurrency:** new task/stream/subscription? Ownership, cancellation, backpressure, shutdown.
  See concurrency, resource-lifecycle.
- **Security/privacy:** does it touch tokens, model I/O, the filesystem, logging, or network egress?
  See privacy, security, offline-first.
- **Tests to change:** unit (`engine/tests`, `apps/desktop/test`), IPC roundtrip, integration.
- **Docs that may go stale:** `docs/*`, `.env.example`, `packages/protocol/README.md`, decisions log.

## Output
State the blast radius explicitly before coding — even a one-line summary ("engine `search/` only;
rebuildable `search.db`; one new test; no IPC/doc change") keeps the change honest and scoped.

## Related skills
minimal-change · api-contracts · schema-evolution · backwards-compatibility · testing · documentation-sync
