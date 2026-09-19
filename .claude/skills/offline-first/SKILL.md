---
name: offline-first
description: Load when a change involves the network or an external runtime, to preserve the invariant that a missing network never unexpectedly breaks local functionality. Documents what actually needs the network vs what degrades gracefully.
---

# offline-first

## The principle
**Network unavailable must not make local-first functionality unavailable.** Notely runs entirely
on-device by default; the network is optional.

## What does NOT need the network
- The whole meeting pipeline (transcript → chunking → extraction → synthesis → IR → MOM → storage):
  the LLM (Ollama/MLX) and ASR are **local** HTTP servers on the same machine, not internet services.
- Vault Search (FTS5), Knowledge Space, reading meetings/MOMs, the editor, the Inbox.
- Ask — degrades to a **deterministic list of matching passages with citations** when the LLM runtime
  is down (citations). It never hard-fails.

## What genuinely needs the network
- **Slack/Teams import** (`sources/`) — reaches those APIs. This is the one real network dependency,
  and it's user-initiated.
- Model **download** (first-time `ollama pull` / fetching weights) — a setup step, not runtime.

## Degradation rules (how "offline" must behave)
- LLM runtime unreachable → enrichment `deferred` (retryable), Ask → passage list. Not a crash.
- Embeddings unavailable/not configured → search is **FTS5-only** (hybrid is a bonus, not a requirement).
- ASR runtime unreachable → audio path errors cleanly; transcript input still works fully.
- A "runtime down" is a **local** condition (server not started), handled the same whether or not the
  internet is up.

## Rule
Don't introduce a network call on a core-processing or vault path. If a feature needs the network, it
must be optional, explicitly so, and everything else must keep working without it. Distinguish
"internet down" from "local runtime not started" — both must degrade, never break.

## Related skills
security · privacy · ai-runtime · search · citations · failure-modes
