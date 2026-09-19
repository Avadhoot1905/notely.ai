---
name: dependency-audit
description: Load when adding, updating, or reviewing dependencies. Notely keeps a deliberately small dependency set with no native/GPU FFI — this skill lists the current deps and the bar a new one must clear.
---

# dependency-audit

## Current footprint (know it before adding)
**Engine (`engine/Cargo.toml`, workspace-pinned):** `serde`, `serde_json`, `thiserror`, `anyhow`,
`tokio`, `tracing`(+`-subscriber`), `async-trait`, `reqwest`, `rusqlite` (**bundled** — no system
SQLite), `uuid`, `chrono`. Dev: `tokio`, `async-trait`, `serde_json`. **No native inference/GPU/FFI
crates** — MLX/Ollama/ASR are external HTTP servers by design (D-0021).

**Desktop (`apps/desktop/pubspec.yaml`):** `file_selector`, `shared_preferences`, `path`, `record`,
`cupertino_icons`; dev `flutter_test`, `integration_test`, `flutter_lints`. State management is **first
-party `ChangeNotifier`/`InheritedWidget`** — no state-mgmt package (keep it that way).

## Bar a new dependency must clear
1. **Is it needed now?** The repo adds capability "only when a real need appears." Prefer std/first-party.
2. **Does it duplicate existing functionality?** (e.g. don't add a second HTTP client, path lib, or a
   state-management framework.)
3. **Native / platform cost?** A dep pulling native code or FFI threatens the "no native inference in
   the engine" and "builds compile on all three platforms" invariants — heavy scrutiny.
4. **Does it break local-first / offline?** No dep may make a local feature require the network.
5. **Update risk / maintenance / license** — matches the workspace license; not abandoned.
6. **Cross-platform:** must build on macOS/Windows/Linux (CI builds all three — a dep that breaks one
   breaks release).

## Prefer instead
Extend an existing seam, use the std/first-party option, or add an **external process over HTTP**
(the established pattern for runtimes) rather than linking a library.

## Related skills
dead-code · minimal-change · release-engineering · security · compatibility-matrix
