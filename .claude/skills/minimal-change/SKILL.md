---
name: minimal-change
description: Load on any implementation task to keep the diff to the smallest coherent change that solves the problem — no drive-by refactors, no speculative generalization. Matches Notely's deliberately-small v0 ethos.
---

# minimal-change

## Default
Make the **smallest coherent change** that solves the problem and leaves the code consistent. Notely
v0 is intentionally minimal (one package, one app, config over frameworks); large diffs fight that.

## Rules
- Change one thing. Don't bundle a fix with a rename, reformat, or "while I'm here" refactor.
- Reuse the existing seam. If a trait/service/controller already fits, extend behind it — don't add
  a parallel path. (E.g. a new ASR backend is a new `AsrProvider` impl, not a new pipeline.)
- Don't generalize for a hypothetical second caller. The repo's own comments say "extend only when a
  real need appears." Add the abstraction when the second caller actually arrives.
- Respect flat structure: `scripts/` and `docs/` stay flat; don't reorganize directories.
- If a refactor is genuinely required to fix the bug, do the refactor as its own reviewable step and
  say so — don't smuggle it inside the fix.

## When a bigger change is justified
Only when the repository evidence demands it (the seam genuinely doesn't support the requirement) or
the user explicitly asks. Then scope it, name the blast radius (see change-impact), and keep even the
big change coherent rather than sprawling.

## Related skills
notely-maintainer · change-impact · no-speculation · dead-code · code-review
