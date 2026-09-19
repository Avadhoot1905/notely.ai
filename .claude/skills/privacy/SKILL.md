---
name: privacy
description: Load whenever a change could move meeting content off-device or into logs — network egress, telemetry, logging, model providers, temp files, crash reports, integrations, or retention. Meeting content is potentially sensitive; Notely's promise is on-device by default.
---

# privacy

## The promise
Notely turns meetings into MOMs **without sending meetings to the cloud** — no mandatory cloud
service, API key, or subscription (`docs/product.md`). Treat all meeting content (audio, transcript,
IR, MOM) and the vault as **potentially sensitive**. Privacy is a core product value, not a nice-to-have.

## Where data could leak — check each on any change
- **Network egress:** by default there is **none** for core processing — the LLM/ASR runtimes are
  **local** HTTP servers on the same machine. The **only** intended outbound network is the
  **Slack/Teams import** (user-initiated). Adding any other network call breaks the promise — don't,
  unless it's explicitly optional and off by default.
- **Telemetry:** none. Don't add analytics/telemetry that carries content or usage without explicit
  opt-in.
- **Logging:** `tracing` at `NOTELY_LOG_LEVEL`. **Never log transcript content, tokens, or vault
  data** at default levels. Tokens must never be logged at any level.
- **Model providers:** local by design. If a future remote provider is ever added, it must be
  explicit, opt-in, and clearly disclosed — never a silent default.
- **Filesystem / temp files:** data lives in the app-data dir; don't scatter temp copies of audio/
  transcripts; clean up any temp artifacts.
- **Crash reports:** must not bundle meeting content, vault contents, or tokens.
- **Integrations:** imported Slack/Teams content becomes provenance-tagged vault notes; tokens are
  **never persisted** (security). Respect the source's data when importing.
- **Retention:** the user owns deletion; deleting a meeting/note should actually remove it (and its
  derived index entries reconcile on sync).

## Rule
Any change that could send content off-device, write it to a new location, or log it must be
called out explicitly and default to off/local. When unsure, keep it local.

## Related skills
security · threat-modeling · offline-first · storage · search
