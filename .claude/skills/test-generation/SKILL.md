---
name: test-generation
description: Load when writing new tests — derive them from the invariant or behavior that changed, not from a coverage target. Points to the right layer (deterministic unit vs fixture-backed vs mirror test) for each kind of Notely change.
---

# test-generation

## Principle
Write the test that would **fail if the invariant broke**, not tests that merely raise coverage. Every
bug fix and every new invariant gets a regression test.

## Map change → test
- **Deterministic Rust logic** (preprocess/chunking, renderer, IR validation, evidence grounding,
  owner/deadline guard) → a plain unit test with a crafted input; **no model needed**. This is where
  most correctness lives — test it directly.
- **AI passes** → use a **fixture/test provider** (not live Ollama) to assert structure/reconciliation
  (see `ai_pipeline.rs`). Real-model behavior goes in the `#[ignore]`d smoke test only.
- **IPC message / schema** → add to `ipc_roundtrip.rs` (Rust) **and** `apps/desktop/test/ipc/`
  (Dart). A protocol change untested on both sides is incomplete.
- **Reliability/recovery invariant** (source-before-AI, deferred-is-retryable, idempotent reprocess,
  startup requeue) → extend `reliability.rs`.
- **Search/index** → `search_index.rs` (sync by fingerprint, FTS5 fallback, deletion reconciliation).
- **Flutter state/behavior** → controller/state test folding the event stream (e.g. LiveMeetingState),
  or a widget test. Audio seams → `apps/desktop/test/audio/`.
- **Platform capability logic** → test the Dart capability/fallback, not the native GUI (which isn't
  runtime-QA'd — see compatibility-matrix).

## Good regression tests here
- Assert the *guarantee*, not the implementation: "AI failure leaves status `deferred` and transcript
  intact", "case-only rename doesn't self-collide", "Ask returns citations even when LLM offline".
- Use `data/fixtures/transcripts/*.json` for realistic pipeline inputs.

## Don't
- Add tests that require a live model/runtime to the default suite.
- Weaken an existing assertion to make a new test pass (see test-triage).

## Related skills
testing · test-triage · debugging · failure-modes · crash-recovery
