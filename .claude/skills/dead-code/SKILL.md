---
name: dead-code
description: Load for maintenance passes hunting unused code, stale flags, abandoned abstractions, or duplicate implementations. Includes how to tell real dead code from Notely's intentional scaffolding (which must NOT be deleted).
---

# dead-code

## Critical distinction: scaffolding is not dead code
Notely deliberately ships **defined-but-unwired seams** and labels them honestly. These are
**intentional and must not be removed**:
- `asr/whisper.rs` returning `AsrError::NotImplemented`; the scaffolded `audio → media → ASR` head.
- The Flutter live-capture seam (VAD/segmenter/`AsrEngine`) with a **mocked** ASR.
- Scaffolded/planned passes (verified-mode LLM critique) and the Cargo workspace "ready to split".
- Windows/Linux native adapters (compile-gated, not yet runtime-verified).
Deleting these because they're "unused" is a regression. Check `docs/decisions.md` /
`docs/pipeline.md` "Status" sections and the file's own doc comment before calling something dead.

## Real dead code to look for
- Truly unreferenced private functions/types (grep for the symbol; both Rust and Dart).
- Duplicate implementations of one concern (e.g. two path helpers, two HTTP clients) — collapse to one.
- Stale config knobs no longer read by `config.rs` (cross-check `.env.example` + `docs/development.md`).
- Abandoned abstractions with a single caller that no longer needs them (but respect "extend when a
  real need appears" — a lone provider impl behind a trait is a feature, not dead code).
- Unused dependencies (see dependency-audit).

## Method
- Rust: `cargo clippy --all-targets -- -D warnings` flags many unused items; grep symbols for callers.
- Dart: `flutter analyze` flags unused; grep across `lib/`.
- Confirm no test, example, or native channel references it before removing.

## Rule
When unsure whether something is dead or scaffolding, **ask/flag rather than delete** — the codebase's
value is partly in its honest, kept seams.

## Related skills
minimal-change · dependency-audit · documentation-sync · no-speculation
