---
name: stop-conditions
description: Load to decide when to stop investigating and start implementing (or answer). Prevents endless exploration of Notely's tree once the implementation path, contracts, and tests are understood.
---

# stop-conditions

## Purpose
Boundaries make Notely fast to understand — which means it's easy to over-explore. Stop when you have
enough to act correctly, not when you've read everything.

## Stop investigating once ALL of these hold
1. **The implementation path is understood** — you know which module/stage/message/channel changes,
   end to end across the boundary.
2. **The affected contracts are identified** — the specific trait(s), IPC message(s), schema(s), or
   DB artifact(s) that change (see change-impact).
3. **The tests are known** — you know which existing tests cover it and which new test to add.
4. **More reading won't change the decision** — remaining files are peripheral to the fix.

## Also stop (and escalate/ask) when
- Two credible interpretations diverge on a *user-facing* decision → ask the user, don't guess.
- The task would require breaking the IPC contract or a source-of-truth schema → confirm scope first
  (backwards-compatibility).
- You've found the answer to a lookup question — return it; don't keep spelunking.

## Don't stop early if
- You haven't found where the data actually crosses the IPC line or which `(meeting_id, kind)`
  artifact / DB is involved — that's the core of most Notely bugs.
- You're assuming platform behavior that's only compile-gated (verify or flag it).

## Related skills
investigation-first · no-speculation · change-impact · debugging
