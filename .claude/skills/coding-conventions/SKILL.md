---
name: coding-conventions
description: Load when writing or editing Rust or Dart in Notely so new code matches the repo's actual style — error handling, trait/provider patterns, the doc-comment-explaining-the-seam habit, Dart controllers/DI, path handling, and the fmt/lint gates.
---

# coding-conventions

## Universal
- **Every file opens with a doc comment explaining the *seam / design intent*** ("why this boundary
  exists", "what must not leak"), not a description of the code. Match this — it's the strongest
  convention in the repo. See `audio_frame.dart`, `asr/provider.rs`, `ai/provider.rs` for the tone.
- Prefer configuration and explicit code over frameworks/abstractions (D-0020, D-0001).
- Keep it small and boring; extend a type "only when a real need appears" (comments say this literally).

## Rust (`engine/`)
- Toolchain pinned in `rust-toolchain.toml`; gates: `cargo fmt --check`,
  `cargo clippy --all-targets -- -D warnings` (warnings are errors), `cargo test`.
- **Errors:** per-module error enum via `thiserror` (`AsrError`, `AiError`, `StorageError`,
  `LlmError`, `SearchError`, `SourceError`, `PipelineError`). Variants are specific and honest
  (e.g. `AsrError::NotImplemented(&'static str)` for a defined-but-unwired backend). No `unwrap()`
  in library paths; return typed errors.
- **Traits are the seams:** async traits use `async_trait`; each swappable backend implements a
  `*Provider`/analyzer/`Store` trait. Callers depend on the trait, never the concrete type.
- **Structured output:** the Rust side owns JSON schemas (`ai/schema.rs`) and passes them to the
  runtime as `format`; the model fills them in. Malformed output errors (with one stricter retry).
- Async: Tokio; blocking SQLite runs on the blocking pool (D-0009). Domain types are plain serde.

## Dart (`apps/desktop/`)
- Gates: `dart format --set-exit-if-changed`, `flutter analyze` (`flutter_lints`), `flutter test`.
- **State:** feature controllers extend `ChangeNotifier`; UI rebuilds via `ListenableBuilder`/
  `AnimatedBuilder`. **No third-party state-management package** — DI is the `AppScope`
  `InheritedWidget` (`lib/app/app_scope.dart`); read via `AppScope.of(context)`.
- **Platform isolation:** no pure UI widget imports `dart:io` or checks `Platform.isX`. OS-specific
  behavior lives behind a service in `lib/services/…` or a helper in `lib/platform/`. See desktop,
  cross-platform doc.
- **Paths:** always `package:path` (`p.join`, `p.relative`, `p.isWithin`), never string concat.
- **Backend access:** features go *through* `EngineClient` (the IPC boundary), never around it.
- Immutable snapshots for UI state (e.g. `LiveMeetingState` with a private `_copy`), folded from an
  event stream — the UI reads the projection, it does not reconstruct state from raw inputs.

## Related skills
architecture · flutter-ui · api-contracts · testing
