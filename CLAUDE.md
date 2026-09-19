# Notely — root context

Notely is a **local-first** desktop app that turns meetings into structured, evidence-backed Minutes
of Meeting (MOM), entirely on-device. Two components, one boundary: a **Flutter desktop app** talks to
a single **Rust engine** over **IPC**. No mandatory cloud, no API key.

## Core principles (verified against the code)
1. **IPC is the only backend boundary.** The Flutter app has no media/ASR/AI/model/storage logic; the
   engine owns everything below the IPC line. `PROTOCOL_VERSION = 4`.
2. **Local-first / offline.** Nothing is required to leave the machine; features degrade, never hard-fail.
3. **AI failure ≠ data loss.** The source (meeting + transcript) is saved *before* any AI runs;
   enrichment status is a separate artifact.
4. **Canonical sources of truth are explicit.** `notely.db` is authoritative; `search.db` / `jobs.db` /
   `llm_cache.db` are derived and rebuildable. The Meeting IR is the contract; the MOM is derived.
5. **Two separate LLM passes** (extraction → synthesis); the LLM emits structured IR, rendering is
   deterministic; provenance/anti-invention is Rust's job. Never `transcript → LLM → MOM`.
6. **Minimal, boring v0.** Configuration over frameworks; one Rust package, one Flutter app.

## Repository map
- `apps/desktop/` — Flutter desktop app (macOS/Windows/Linux). UI only. → `apps/desktop/CLAUDE.md`
- `engine/` — single Rust package `notely-engine` (the backend). → `engine/CLAUDE.md`
- `packages/protocol/` — canonical IPC contract (Rust + Dart mirror it). → `packages/protocol/CLAUDE.md`
- `docs/` — authoritative architecture prose (flat). Start with `architecture.md`, `decisions.md`.
- `models/manifests/` — model manifests (`qwen3`, `qwen3-asr`, `whisper`). **Weights never in repo.**
- `scripts/` — flat dev scripts. `.github/workflows/` — `ci.yml`, `release.yml`.
- `.claude/skills/` — **the modular skill library** (reusable problem-solving knowledge; see below).

## Architectural overview
```
Flutter app ──IPC (NDJSON/loopback TCP 127.0.0.1:8765)──▶ Rust engine
engine: media → asr → preprocess → ai(extraction→synthesis→validation) → renderer → storage
        (+ search over the Markdown vault; + Slack/Teams source import)
```
Two Qwen models on two runtimes: **Qwen3-ASR** (separate HTTP runtime, *not* Ollama) for speech-to-text;
**Qwen3 1.7B** on **Ollama** for meeting understanding; deterministic Rust between them.

## Three layers of context (keep distinct)
- **Root CLAUDE.md (this file)** — what Notely is and how to work on it generally.
- **Module CLAUDE.md** — what's special about working *in that directory*. They exist at:
  `apps/desktop/`, `apps/desktop/lib/services/`, `engine/`, `engine/src/storage/`,
  `engine/src/sources/`, `packages/protocol/`.
- **Skills (`.claude/skills/`)** — reusable, problem-type knowledge. Start with `.claude/skills/README.md`
  (index). Load only what the task needs (e.g. a transcription bug → `ingestion` + `meeting-ir` +
  `storage` + `crash-recovery` + `debugging` + `testing`).

## Working methodology
1. Read this root file. 2. Locate the target module and read its `CLAUDE.md`. 3. Load the relevant
skills. 4. Inspect the actual implementation (and its tests) before changing it. 5. Determine change
impact. 6. Make the **smallest coherent change** that preserves existing boundaries. 7. Test the changed
behavior. 8. Update `docs/` (+ a `docs/decisions.md` entry) if architectural behavior changes.
Don't refactor unrelated code; don't edit generated files (see module notes).

## Commands (verified)
```bash
./scripts/bootstrap.sh     # first-time setup (toolchains + deps)
./scripts/dev.sh           # run engine + desktop together
./scripts/check.sh         # cargo fmt --check + clippy -D warnings; dart format check + flutter analyze
./scripts/test.sh          # cargo test + flutter test
./scripts/build.sh         # release build of engine + desktop
./scripts/download-models.sh   # ollama pull qwen3:1.7b (weights are out-of-repo)
```
Engine AI path needs **Ollama** running with `qwen3:1.7b`. The live end-to-end AI test is
`cargo test -p notely-engine --test ollama_smoke -- --ignored --nocapture` (ignored by default). Config
is via env vars — see `engine/src/config.rs`, `.env.example`, `docs/development.md`.

## Agent navigation rule
Before modifying code: (1) read root CLAUDE.md → (2) locate the module → (3) read applicable nested
CLAUDE.md files → (4) load relevant skills → (5) inspect the implementation → (6) determine change
impact → (7) make the smallest coherent change → (8) test it.
