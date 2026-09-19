---
name: testing
description: Load when adding or running tests — the actual test layout across Rust and Flutter, what each layer covers, the Ollama-gated smoke test, CI gates, and how to run the suites. Grounds test work in Notely's real pyramid.
---

# testing

## The pyramid (what exists)
**Engine (Rust) — `engine/tests/`:**
- `domain_serde.rs` — domain (de)serialization / schema stability.
- `transcript_prep.rs` — deterministic preprocess/chunking.
- `ai_pipeline.rs` — extraction→synthesis with a test/fixture provider (no live model).
- `pipeline_order.rs` — orchestrator stage ordering + events.
- `reliability.rs` — "source saved before AI", deferred status, recovery guarantees.
- `search_index.rs` — FTS5 index sync/search.
- `ipc_roundtrip.rs` — IPC request/response/event serialization.
- `ollama_smoke.rs` — **real end-to-end against a live Qwen3 1.7B; `#[ignore]` by default** so the
  normal suite never depends on Ollama. Run with `-- --ignored --nocapture`.
- Plus in-module `#[cfg(test)]` unit tests throughout `engine/src/`.

**Desktop (Flutter) — `apps/desktop/test/` + `integration_test/`:**
- unit/widget/state: `audio/*`, `ipc/*`, `ask/*`, `inbox/*`, `knowledge/*`, `meeting_*`, `session_*`,
  `cross_platform_fs_test.dart`, `platform*_test.dart`, `theme_test.dart`, `widget_test.dart`, …
- integration: `integration_test/app_test.dart`, `audio_capture_it_test.dart`.

## Run
```bash
./scripts/test.sh                 # cargo test + flutter test
cargo test                        # engine
cargo test -p notely-engine --test ollama_smoke -- --ignored --nocapture   # live model
cd apps/desktop && flutter test && flutter test integration_test
./scripts/check.sh                # fmt/clippy + dart format/analyze (run before tests)
```

## CI gates (`.github/workflows/ci.yml`, on push to `main`)
Engine: `cargo fmt --check` + `clippy --all-targets -- -D warnings` + `cargo test` (ubuntu).
Desktop: `dart format --set-exit-if-changed` + `flutter analyze` + `flutter test` (ubuntu). Plus
compile-only build jobs for macOS/Windows/Linux. **Live-model tests are NOT in CI** (ignored) — keep it so.

## Principles
- Tests must not depend on a running Ollama/ASR/MLX (use fixtures / `fixture` providers). Real-model
  paths stay `#[ignore]`.
- A protocol/schema change updates both the Rust and Dart mirror tests.
- Deterministic stages (preprocess, renderer, validation, evidence grounding) are unit-testable
  without any model — prefer testing them directly.

## Related skills
test-generation · test-triage · debugging · code-review · ipc · ingestion
