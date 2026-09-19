---
name: security
description: Load when touching a trust boundary — the local IPC socket, the filesystem/vault, imported files, model inputs/outputs, external runtime subprocesses, or the Slack/Teams integrations. Documents Notely's actual security surfaces and the token-handling rule.
---

# security

## Trust model
Notely is **local-first**: the primary trust boundary is the user's own machine. There's no cloud
backend, no mandatory account. Security work is mostly about **not leaking sensitive local data** and
**not trusting inputs/outputs blindly**. See threat-modeling for structure, privacy for data handling.

## Actual boundaries and surfaces
- **IPC socket** — loopback **TCP `127.0.0.1:8765`** (NDJSON). It's local-only framing (not a web
  server), but a loopback TCP port is reachable by other local processes. Treat it as a local trust
  boundary: validate/deserialize every message; version-check envelopes; don't expose it beyond loopback.
- **Filesystem / vault** — the engine reads/writes the user's Markdown vault and app-data DBs. Build
  paths with `package:path`; keep operations within the intended vault (`p.isWithin`); don't follow
  untrusted paths out of the vault.
- **Imported files / recordings** — treated as untrusted content; parsing is bounded and errors are
  typed, not panics.
- **Model inputs/outputs** — LLM/ASR **output is untrusted**: the model may fabricate. Anti-invention
  guards (owner/deadline, participant backfill) and schema validation are the mitigation — never render
  raw model text as fact without the deterministic guards.
- **External runtime subprocesses / HTTP** — Ollama/MLX/ASR are separate local servers over HTTP;
  Notely doesn't link them. Native detection uses `g_spawn_sync` with explicit `argv` (no shell) and
  XML-escapes toast content — keep that discipline (no shelling out with interpolated strings).
- **Slack/Teams integrations** — network egress to those APIs with a user token (see privacy). Tokens
  are the crown jewels here.

## The token rule (non-negotiable)
Source **tokens are passed in-memory per request and NEVER persisted** by the engine; only non-secret
bookkeeping (what's connected/imported) is stored. Don't log them, cache them, or write them to disk.

## Rules
- Validate at the boundary; never `unwrap()` on external input.
- No shell interpolation for native process invocation.
- Don't widen the IPC bind beyond loopback.
- Treat model output as untrusted; keep deterministic validation/grounding in the path.

## Related skills
threat-modeling · privacy · offline-first · api-contracts · ipc
