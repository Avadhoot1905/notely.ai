---
name: notely-maintainer
description: The senior-maintainer operating philosophy for Notely. Load on any change to keep decisions aligned with the project's established boundaries, sources of truth, and "don't over-build" ethos. Pairs with minimal-change and no-speculation.
---

# notely-maintainer

## Operating philosophy
Notely is a deliberately small, boring, local-first v0. The engineering value is in *clean
boundaries kept clean*, not in cleverness. Act like the person who will maintain this in a year.

## Rules
1. **Understand before modifying.** Read the module's `provider.rs`/`mod.rs`, its callers, and its
   tests first. See investigation-first.
2. **Preserve established boundaries.** IPC is the only backend boundary; `ai/` never speaks HTTP;
   Flutter never holds backend logic; `domain/` stays dependency-free. Don't route around a trait.
3. **Identify the canonical source of truth and don't duplicate state.** `notely.db` is the meeting
   source of truth; `search.db`/`jobs.db`/`llm_cache.db` are derived/rebuildable. `MeetingIr` is the
   contract; the MOM is derived. `MeetingSessionManager` is the single meeting-state owner.
4. **Minimize abstractions.** This repo prefers configuration over frameworks (per-task model
   routing is env vars, not a router — D-0020) and one Rust package over premature crate-splitting
   (D-0001). Don't add layers "for the future."
5. **Maintain backwards compatibility** for existing vaults, DBs, configs, and the IPC contract.
   See backwards-compatibility and schema-evolution before any breaking change.
6. **Add a regression test** with every bug fix and every new invariant. See test-generation.
7. **Keep docs in step.** Architectural change → update `docs/` and add a `docs/decisions.md` entry.
   See documentation-sync.
8. **No speculative redesign.** Don't "modernize" the pipeline, swap the transport, or restructure
   modules unless the task requires it and the repo evidence supports it.

## Signals you're going the wrong way
- Adding backend logic to Flutter, or media/ASR/AI logic outside its engine module.
- Making the LLM emit final Markdown, or collapsing extraction+synthesis into one call.
- Persisting a source token, or making a local feature hard-fail when the network is down.
- Introducing a second copy of meeting/transcript state (e.g. in the overlay).
- A large diff for a small bug.

## When the repo and your assumption disagree
The code wins. If `docs/` conflicts with code (e.g. protocol version), trust code and note the doc
drift (see documentation-sync). Flag anything you cannot verify rather than asserting it.

## Related skills
minimal-change · no-speculation · investigation-first · change-impact · documentation-sync · code-review
