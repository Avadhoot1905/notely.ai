---
name: citations
description: Load when working on Ask answers or evidence traceability — how retrieved passages become Citations (path + line range + snippet), how the answer stays grounded regardless of what the model writes, and the deterministic fallback. Distinct from Meeting IR Evidence.
---

# citations

## Two kinds of traceability in Notely (don't conflate)
1. **Meeting IR `Evidence`** — a transcript span (`quote, speaker_id, start, end, chunk_id`) attached
   to a decision/action. See meeting-ir. This is about *a meeting's* claims.
2. **Ask `Citation`** — a vault-note span (`path, start_line, end_line, snippet`) backing an answer.
   This is about *the vault's* answers. Covered here.

## How Ask citations work (`engine/src/search/qa.rs`)
- Retrieval returns `Passage`s from the index; each becomes a `Citation { path, start_line, end_line,
  snippet }`. **Citations are built deterministically from the retrieved passages** — the answer stays
  traceable regardless of what the model writes.
- The prompt instructs the model to answer **using only these sources, citing them by number** and to
  say plainly when the answer isn't in them ("Never invent facts, names, dates, or sources").
- Result type: `AskAnswer { text, citations, … }` (`domain`), returned as IPC `Response::Answer`.

## Deterministic fallback (never fails)
If the LLM runtime is unavailable, `Ask` returns a deterministic list of the matching passages with
their citations instead of failing (`fallback_text`). This is the offline-first guarantee at the
answer level (see offline-first). An answer is never emitted without its backing citations.

## Line numbering
Passages store 0-based `start_line`/`end_line`; user-facing rendering adds 1 (`line {n+1}` /
`lines {a+1}-{b+1}`). Keep that convention if you touch citation formatting.

## UI
Citations power "jump to source" in the app (Ask panel). Keep `path` + line range accurate so the
jump lands correctly.

## Related skills
search · meeting-ir · storage · offline-first · large-vault · testing
