---
name: threat-modeling
description: Load when assessing the security of a change or feature. A structured method (assets → trust boundaries → attack surfaces → threats → mitigations → residual risk) grounded in Notely's actual local-first design. Identify plausible surfaces; do not manufacture vulnerabilities.
---

# threat-modeling

## Method (apply to the specific change)
1. **Assets** — what's worth protecting here.
2. **Trust boundaries** — where control/format/trust changes.
3. **Attack surfaces** — how untrusted input reaches an asset.
4. **Threats** — realistic misuse at each surface.
5. **Mitigations** — what's in place / what you'll add.
6. **Residual risk** — what remains, stated honestly.

## Notely assets
Meeting audio/transcripts, the Meeting IR/MOM, the user's Markdown vault, **source tokens**
(Slack/Teams), and local DBs (`notely.db` etc.).

## Trust boundaries
- User's machine ⟷ external model runtimes (Ollama/MLX/ASR over local HTTP).
- App ⟷ engine (loopback TCP IPC).
- Engine ⟷ filesystem (vault, app-data).
- Engine ⟷ Slack/Teams APIs (the one routine network egress).
- Model output ⟷ rendered facts (the model is untrusted).

## Representative threats & mitigations
- **Other local process hits the IPC port** → version-checked, validated NDJSON; keep bind on
  loopback; don't expose secrets over IPC. *(Residual: any local process can connect — a local-trust
  assumption, documented.)*
- **Path traversal via imported/vault paths** → `package:path` + `p.isWithin`; bound operations to the vault.
- **Token exfiltration** → tokens never persisted/logged; in-memory per request only (security, privacy).
- **Model fabricates a fact/owner/date** → deterministic anti-invention guards + schema validation +
  evidence grounding. Never render raw model text as authoritative.
- **Command injection via native detection** → `g_spawn_sync` explicit `argv`, XML-escaped toasts,
  no shell. Keep it.
- **Malicious import content** → bounded parsing, typed errors, provenance-tagged notes.

## Rules
Identify **plausible surfaces grounded in the implementation** — don't invent vulnerabilities the
architecture precludes (there is no cloud backend, no linked GPU FFI, no web server). State residual
risk rather than overclaiming safety.

## Related skills
security · privacy · offline-first · api-contracts
