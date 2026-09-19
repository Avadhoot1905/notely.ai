---
name: test-triage
description: Load when tests fail — a disciplined sequence to find the first meaningful failure, reproduce it, distinguish regression from flakiness/environment, and fix the root cause without weakening tests to make CI green.
---

# test-triage

## Sequence
1. **Find the first meaningful failure.** Read from the top; a later failure is often a cascade. In
   Rust, the first failing assertion; in Flutter, the first failing test/expectation.
2. **Reproduce locally, narrowly.** Run just that test: `cargo test <name>` or
   `flutter test test/<file>.dart --plain-name '<name>'`. Confirm it fails deterministically.
3. **Classify:**
   - *Regression* — your change broke a real invariant → fix the code.
   - *Environment* — needs Ollama/ASR/MLX/FFmpeg/`pactl`, or is a native/GUI path. Live-model tests are
     `#[ignore]`d; if one ran, that's the issue. Windows/Linux native behavior isn't runtime-tested.
   - *Flakiness* — timing/async (streams, microtasks, broadcast) or ordering. Look for missing
     `await`, uncancelled subscriptions, or reliance on wall-clock.
4. **Inspect the implementation** the test guards (its trait, the stage, the mirror on the other side
   of IPC). See investigation-first.
5. **Fix the root cause**, then re-run the narrow test, then the suite + `./scripts/check.sh`.

## Hard rule
**Never weaken a test to make CI green.** Don't loosen an assertion, delete a case, add a blanket
`skip`, or change expected values without proving the new value is correct. If a test is genuinely
wrong, fix it deliberately and explain why (with evidence) — that's a separate, reviewable change.

## Notely-specific gotchas
- A default-suite failure that needs a live model means a test wrongly isn't `#[ignore]`d.
- IPC test failing on one side only → the Rust/Dart mirrors diverged; sync them + bump version if the
  wire changed.
- Async Dart flakiness → bounded-buffer/broadcast-stream timing; assert on the folded snapshot, not
  intermediate emissions.

## Related skills
testing · debugging · test-generation · failure-modes · investigation-first
