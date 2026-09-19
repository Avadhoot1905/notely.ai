---
name: code-review
description: Load when reviewing a Notely diff (yours or a contributor's). A checklist tuned to this codebase — boundary integrity, the two-pass/provenance invariants, IPC three-places, platform parity, reliability, privacy, and tests.
---

# code-review

## Boundary & architecture
- Does anything put **backend logic in Flutter** or media/ASR/AI logic outside its engine module?
- Does the code **route around a trait** (`LlmProvider`/`AsrProvider`/`AiAnalyzer`/`Store`) or the
  IPC boundary? It shouldn't.
- Did the LLM start emitting final Markdown, or did extraction+synthesis collapse into one call? (No.)
- Is a **second copy of meeting/transcript state** introduced (esp. in the overlay)? (No.)

## Contracts & compatibility
- IPC change: updated **all three** (`packages/protocol`, Rust `ipc`, Dart `ipc`) + version bump + both
  mirror tests? (api-contracts, ipc)
- Schema/persistence: additive where possible; old stored IR/status/config still loads;
  source-of-truth change has a migration. (schema-evolution, backwards-compatibility)

## Concurrency & lifecycle
- Cancellation checked between units of long work; resources (streams, recorder, connections, windows,
  companion engine) released on error/cancel paths. (concurrency, resource-lifecycle)
- Bounded buffers keep drop-oldest + counted drops; no blocking of the recorder callback.

## Reliability & correctness
- Source saved **before** AI; failures → `deferred` (retryable), not lost; reprocess stays idempotent.
- Provenance/anti-invention preserved (evidence grounding, owner/deadline guard, participant backfill).
- Error paths return typed errors and **degrade** (unreachable runtime, missing FFmpeg/`pactl`) — no
  silent stubs, no crashes.

## Privacy & offline
- No source **token persisted**; no meeting content in logs/telemetry/network egress. (privacy)
- No new mandatory network dependency for a local feature. (offline-first)

## Platform
- Native `notely/*` channel/payload changes applied to **all four** implementations; no `dart:io`/
  `Platform.isX` in UI widgets; paths via `package:path`. No unverified Windows/Linux claims.

## Quality
- Smallest coherent change; no drive-by refactors (minimal-change).
- File opens with a seam/intent doc comment; passes `./scripts/check.sh`.
- Regression test added; docs/decisions updated if architecture changed (documentation-sync).

## Related skills
notely-maintainer · change-impact · testing · security · privacy · documentation-sync
