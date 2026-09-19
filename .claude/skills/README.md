# Notely skill library

A modular knowledge base for working on Notely. Each skill under `.claude/skills/<name>/SKILL.md`
encodes repository-specific architecture, invariants, and workflows. Load only the skills relevant
to your task — this file is the map.

Notely is a **local-first** desktop meeting-intelligence app: a Flutter desktop UI talking to a
single Rust engine over IPC, turning meetings into evidence-backed Minutes of Meeting (MOM),
entirely on-device. Authoritative prose lives in [`docs/`](../../docs); these skills are the
agent-facing distillation and cross-reference it.

## Always relevant (load for almost any task)

- **repo-navigation** — where things live; find code without reading the whole tree.
- **architecture** — the two components, the IPC boundary, the processing pipeline, the invariants.
- **notely-maintainer** — senior-maintainer operating philosophy for this repo.
- **coding-conventions** — Rust + Dart conventions actually used here.
- **investigation-first** — require evidence before implementing.
- **minimal-change** — smallest coherent change; no drive-by refactors.
- **no-speculation** — don't invent APIs, invariants, or requirements.
- **stop-conditions** — when to stop investigating and act.

## Task-specific

Contracts & evolution: **api-contracts · schema-evolution · backwards-compatibility · concurrency ·
resource-lifecycle · change-impact**

Ingestion & AI pipeline: **ingestion · audio · asr · meeting-ir · extraction · synthesis ·
ai-runtime · ollama · apple-silicon · cuda**

Data: **storage · search · citations · large-vault**

Desktop: **flutter-ui · desktop · overlay · ipc**

Quality: **testing · test-generation · test-triage · code-review · debugging · failure-modes ·
crash-recovery**

Security/privacy: **security · threat-modeling · privacy · offline-first**

## Periodic / maintenance

**dependency-audit · dead-code · documentation-sync · profiling · performance-budget ·
migration · large-vault · compatibility-matrix · release-engineering · open-source-maintainer**

## Example loadouts

- *Fix a transcription persistence bug* → repo-navigation + architecture + ingestion + meeting-ir +
  storage + crash-recovery + debugging + testing.
- *Improve the desktop transcription widget* → repo-navigation + architecture + desktop + overlay +
  ipc + flutter-ui + testing.
- *Add an IPC message* → repo-navigation + api-contracts + ipc + schema-evolution +
  backwards-compatibility + testing.
- *Change the search index* → repo-navigation + storage + search + citations + large-vault +
  migration + testing.

## Facts every skill assumes (verified against the tree)

- IPC is the **only** backend boundary; `PROTOCOL_VERSION = 4` (Rust `engine/src/ipc/protocol.rs`
  and Dart `apps/desktop/lib/ipc/protocol.dart`). Note: `docs/ipc.md` prose still says "currently 3"
  — the code is authoritative at 4.
- One Rust package (`engine`, lib `notely_engine` + thin bin), one Flutter app (`apps/desktop`).
- Two Qwen models on two runtimes: **Qwen3-ASR** (separate HTTP runtime, *not* Ollama) for
  speech-to-text; **Qwen3 1.7B** on **Ollama** for meeting understanding; deterministic Rust between.
- Source of truth DB is `notely.db`; `search.db` / `jobs.db` / `llm_cache.db` are derived and
  rebuildable.
