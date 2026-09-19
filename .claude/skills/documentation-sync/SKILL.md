---
name: documentation-sync
description: Load after any behavior/architecture change to keep docs truthful — which of README, docs/*, decisions log, .env.example, packages/protocol, and these skills need updating. Notely's docs are detailed and meant to stay accurate.
---

# documentation-sync

## Notely's docs are load-bearing
`docs/` is detailed and authoritative for intent. When you change behavior, the matching doc must
change too, or future agents (and this skill library) go stale.

## What to update for a given change
| Change | Update |
|---|---|
| IPC protocol | `packages/protocol/README.md` + `schema/ipc.schema.json`, `docs/ipc.md`, version notes, **and the `ipc`/`api-contracts` skills** |
| New/changed env knob | `engine/src/config.rs`, `.env.example`, `docs/development.md` table |
| Pipeline / AI behavior | `docs/pipeline.md`, `docs/ai-engine.md`, `docs/meeting-ir.md` |
| Storage / schema | `docs/storage.md` |
| Platform / native behavior | `docs/cross-platform.md`, `docs/meeting-companion.md` (incl. capability matrix) |
| A real architectural decision | **Add a `docs/decisions.md` entry** (D-00xx, newest first, short: what + why) |
| Product scope | `docs/product.md`, `README.md` |
| Anything a skill asserts | update the affected `.claude/skills/*/SKILL.md` |

## Known existing drift (fix opportunistically, don't assert the stale value)
- `docs/ipc.md` prose says protocol "currently 3"; the code (`protocol.rs`/`protocol.dart`) is **4**.
- `docs/decisions.md` D-0008 mentions `qwen3:4b` as the dev default; the current default is
  `qwen3:1.7b` (D-0012 supersedes it — decisions are a historical log, newest wins).

## Rule
Docs describe the *current* system. When code and doc conflict, **code wins**; either fix the doc or
flag the drift. A decisions-log entry is append-only history; superseding entries, not editing old
ones, is the convention. Keep this skill library in step with the same changes.

## Related skills
notely-maintainer · schema-evolution · api-contracts · release-engineering · open-source-maintainer
