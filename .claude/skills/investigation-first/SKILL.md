---
name: investigation-first
description: Load at the start of any debugging or change task to enforce evidence-before-implementation — read the interface, callers, and tests, and trace real data flow before writing code. Counters guessing in a two-language, boundary-heavy codebase.
---

# investigation-first

## Principle
Notely spans Rust + Dart + native code with strict boundaries. Guessing across a boundary is how you
break the wrong thing. Gather evidence first; the boundaries make evidence cheap to find.

## Do this before implementing
1. **Read the contract.** The module's `provider.rs`/`mod.rs` trait or the IPC message defines inputs,
   outputs, and errors. Start there, not at the call site.
2. **Read the callers.** Grep for the trait/method/message to see how it's actually used and what
   assumptions callers make.
3. **Read the tests.** `engine/tests/*` and `apps/desktop/test/*` encode the expected behavior and
   invariants — often the fastest spec. Match test names to your subsystem.
4. **Trace the real data flow** across the boundary: which IPC message, which stage in
   `orchestrator.rs`, which DB artifact `(meeting_id, kind)`, which `notely/*` channel.
5. **Reproduce** where feasible (a fixture transcript, an `--ignored` smoke test, a widget test)
   before changing anything. See debugging.

## Cheap evidence sources
- `docs/decisions.md` — *why* something is the way it is (don't undo a decision blindly).
- `data/fixtures/transcripts/*.json` — real inputs for the AI path.
- `engine/tests/ollama_smoke.rs` / `cargo run --example transcript_to_mom` — end-to-end truth.
- Error enums — they enumerate the real failure modes of a module.

## Anti-pattern
Editing an implementation because it "looks wrong" without reading its trait, callers, and test.
If you can't cite the file/line that motivates the change, you haven't investigated yet.

## Related skills
repo-navigation · no-speculation · debugging · stop-conditions · testing
