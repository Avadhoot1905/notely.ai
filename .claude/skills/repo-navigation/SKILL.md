---
name: repo-navigation
description: Use FIRST on almost any Notely task to locate the right code fast — repository map, subsystem boundaries, authoritative files, entry points, tests, generated/out-of-repo files, and good search starting points. Load before broad exploration.
---

# repo-navigation

## Purpose
Find the relevant code with targeted search instead of reading the tree. Notely has two components
and clean module boundaries; knowing them turns most "where is X" into one grep.

## Top-level map
- `apps/desktop/` — Flutter desktop app (Dart ≥3.12; macOS/Windows/Linux). **All UI, no backend logic.**
- `engine/` — single Rust package `notely-engine` (lib `notely_engine` + thin `main.rs`). Owns
  everything below the IPC line.
- `packages/protocol/` — canonical IPC contract (`README.md`, `schema/ipc.schema.json`).
- `docs/` — authoritative architecture prose (flat, no subdirs). Start here for intent.
- `models/manifests/` — `qwen3.yaml`, `qwen3-asr.yaml`, `whisper.yaml`. **Weights are never in the repo.**
- `scripts/` — flat dev scripts (`bootstrap/dev/start-engine/start-desktop/check/test/build/…`).
- `.github/workflows/` — `ci.yml`, `release.yml`.
- Root: `Cargo.toml` (workspace), `Makefile`, `justfile`, `rust-toolchain.toml`, `.env.example`.

## Engine modules (`engine/src/`) — authoritative files
- `domain/` — portable types: `meeting.rs`, `transcript.rs`, `meeting_ir.rs`, `processing.rs`,
  `knowledge_map.rs`, `action_item.rs`, `decision.rs`, `participant.rs`. Depends on nothing but serde.
- `ipc/` — `protocol.rs` (requests/responses, `PROTOCOL_VERSION=4`), `events.rs`, `server.rs` (transport).
- `pipeline/` — `orchestrator.rs` (stage ordering + events + cancellation), `jobs.rs` (`CancelFlag`,
  `JobRegistry`), `job_store.rs` (`jobs.db`).
- `media/` — `ffmpeg.rs`, `vad.rs`. `asr/` — `provider.rs` (trait), `qwen3_asr.rs`, `whisper.rs`.
- `preprocess/` — `chunking.rs` (deterministic normalize + chunk).
- `ai/` — `provider.rs` (`AiAnalyzer`), `extraction.rs`, `synthesis.rs`, `validation.rs`,
  `findings.rs` (`ChunkFindings`), `schema.rs` (Rust-owned JSON schemas).
- `llm/` — `provider.rs` (`LlmProvider`), `ollama.rs`, `mlx.rs`, `cache.rs` (`CachingLlmProvider`), `model.rs`.
- `search/` — `index.rs` (FTS5 + embeddings), `chunker.rs`, `qa.rs` (Ask/citations), `mod.rs`.
- `sources/` — Slack/Teams import (`slack.rs`, `teams.rs`, `registry.rs`, `model.rs`).
- `storage/` — `database.rs`, `repositories/mod.rs` (`Store` trait). `renderer/` — `markdown.rs`/`html.rs`/`json.rs`.
- `config.rs` — env-var config. Engine tests: `engine/tests/*.rs`.

## Flutter map (`apps/desktop/lib/`)
- `app/` — `app.dart` (runtime), `app_scope.dart` (InheritedWidget DI — no state-mgmt package), `theme*`.
- `ipc/` — `protocol.dart` (`protocolVersion=4`), `engine_client.dart` (mirror of Rust IPC).
- `features/<feature>/` — UI + `ChangeNotifier` controllers: `ask`, `editor`, `explorer`, `inbox`,
  `integrations`, `knowledge`, `listening`, `meetings`, `stash`.
- `services/` — native/platform seams: `audio/`, `asr/`, `meeting/`, `ask/`, `companion/`,
  `filesystem/`, `meetings/` (detection), `notifications/`, `platform/`, `transcript/`, `window/`.
- `companion/companion_main.dart` — second Flutter engine entrypoint for the overlay.
- Native runners (per-OS `notely/*` channels): `macos/Runner/MainFlutterWindow.swift`,
  `windows/runner/notely_runtime.cpp`, `linux/runner/notely_runtime.cc`.
- Tests: `apps/desktop/test/`, `apps/desktop/integration_test/`.

## Generated / out-of-repo (don't hand-edit / don't expect in tree)
- Model weights (fetched via `scripts/download-models.sh`).
- App data: `notely.db`, `search.db`, `jobs.db`, `llm_cache.db` live in the OS app-data dir
  (`NOTELY_DATA_DIR`), **not** the working tree — see `scripts/reset-data.sh`.
- `Cargo.lock` and Flutter build outputs under `build/`.

## Search starting points
- IPC message → `engine/src/ipc/protocol.rs` + `apps/desktop/lib/ipc/protocol.dart`.
- An env knob → `engine/src/config.rs` + `.env.example` + `docs/development.md` table.
- "Why is it done this way" → `docs/decisions.md` (D-0000…D-0021, newest first).
- A trait/seam → grep the `*/provider.rs` in the module.

## Related skills
architecture · coding-conventions · ipc · api-contracts
