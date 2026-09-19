---
name: debugging
description: Load when chasing a bug — an evidence-driven workflow for a two-language, boundary-heavy system. reproduce → locate subsystem → trace the boundary → find the first incorrect state → fix root cause → regression test → verify.
---

# debugging

## Workflow
1. **Reproduce.** Use the cheapest reliable path: a fixture transcript
   (`data/fixtures/transcripts/*.json`), a unit/widget test, the `transcript_to_mom` example, or the
   `--ignored` smoke test. A bug you can't reproduce, you can't confirm fixed.
2. **Locate the subsystem.** Which side of IPC? Which engine module / pipeline stage / `features/*`
   controller / native `notely/*` channel? repo-navigation maps it.
3. **Trace the boundary.** Most Notely bugs live at a seam: the IPC wire (Rust↔Dart mirrors), a
   `(meeting_id, kind)` artifact, a provider trait, a stream/subscription, or a native channel payload.
   Follow the data across the boundary, not just within one file.
4. **Inspect runtime state.** Rust: `tracing` (`NOTELY_LOG_LEVEL=debug`), targeted `dbg!`/asserts.
   Dart: `flutter analyze`, widget/state tests, logging the folded snapshot. Check the DBs
   (`notely.db` etc.) if persistence is involved.
5. **Find the first incorrect state** — the earliest point where a value diverges from expected. Fix
   *there*, not at the symptom downstream.
6. **Fix the root cause**, add a **regression test** at the right layer (test-generation), then verify:
   narrow test → suite → `./scripts/check.sh`.

## Boundary-specific tips
- Wrong data in the UI but right in the engine (or vice versa) → the IPC mirrors diverged or a field
  isn't serialized. Check both `protocol.rs` and `protocol.dart`.
- Enrichment "lost" → check `processing_status` and `jobs.db`; the source should still be intact
  (crash-recovery). It's usually `deferred`, not gone.
- Async Dart weirdness → uncancelled subscription, microtask timing, or reconstructing state from raw
  frames instead of reading the projection (concurrency).
- "Not working" on a runtime path → is Ollama/ASR/MLX actually reachable? Unreachable → deferral, by design.

## Don't
Guess a cause without reproducing; fix the symptom; or leave the fix without a regression test.

## Related skills
investigation-first · test-triage · failure-modes · crash-recovery · ipc · concurrency
