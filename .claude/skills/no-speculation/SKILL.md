---
name: no-speculation
description: Load whenever you're tempted to assert an API, invariant, requirement, failure cause, or performance claim you haven't verified in Notely's code or docs. Enforces stating uncertainty instead of inventing.
---

# no-speculation

## Principle
Do not invent. In this repo, invented facts are especially costly because behavior is honest about
its own gaps (e.g. "not implemented", "compile-gated by CI only", "reported as generic meeting").

## Do not fabricate
- **APIs / methods / fields** — grep before you call. If it isn't in `protocol.rs`/`protocol.dart`,
  a `provider.rs`, or `meeting_ir.rs`, it doesn't exist.
- **Architectural intent** — cite `docs/decisions.md` (D-00xx) rather than guessing "why".
- **Invariants** — verify against code/tests before presenting something as a rule.
- **Requirements** — don't assume unstated product goals; `docs/product.md` bounds v0 scope.
- **Failure causes** — reproduce or read logs/tests; don't guess. See debugging.
- **Performance problems / budgets** — the repo defines few numeric budgets; don't invent them. See
  performance-budget, profiling.
- **Platform behavior** — Windows/Linux native adapters are compile-gated only and *not* runtime-QA'd;
  don't claim verified behavior. See compatibility-matrix, cross-platform doc.

## When evidence is insufficient
Say so plainly: "I can't verify X from the repo" and state what you'd need to check. Mark a claim as
an observation or "requires verification" rather than an invariant. This mirrors how the codebase
itself flags unverified areas.

## Doc-vs-code conflicts
Code wins. Example: `docs/ipc.md` prose says protocol "3", but `protocol.rs`/`protocol.dart` define
`4`. Report the drift; don't propagate the stale value.

## Related skills
investigation-first · notely-maintainer · debugging · no-speculation-adjacent (performance-budget, compatibility-matrix)
