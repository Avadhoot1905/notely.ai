---
name: release-engineering
description: Load when working on builds, packaging, or releases — the CI gates, the tag-triggered release workflow, per-platform build commands/outputs, and the signing/install caveats. Grounded in the actual .github/workflows and scripts.
---

# release-engineering

## CI vs Release
- **CI** (`.github/workflows/ci.yml`, on push to `main`): engine `fmt`+`clippy -D warnings`+`test`;
  desktop `dart format`+`analyze`+`test`; plus **compile-only** build jobs for macOS/Windows/Linux.
  These builds are the **compile gate** for the Windows/Linux native adapters (a macOS dev can't build
  them locally). CI does **not** run the live-model smoke test.
- **Release** (`.github/workflows/release.yml`, on tag `v*`): builds each platform in `--release`,
  archives, and attaches to a GitHub Release named after the tag. `permissions: contents: write`.
  ```bash
  git tag v1.2.0 && git push origin v1.2.0
  ```

## Build commands / outputs (per platform, on that platform's host)
```bash
# macOS (verified reference host)
cd apps/desktop && flutter build macos --release
# Windows (on Windows)
flutter build windows --release   # → build/windows/x64/runner/Release/notely.ai.exe (zipped: notely-windows-x64.zip)
# Linux (deps: ninja-build cmake clang pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev)
flutter build linux --release     # → build/linux/x64/release/bundle/ (tar: notely-linux-x64.tar.gz)
```
`./scripts/build.sh` does a release build of engine + desktop. Weights are **not** shipped in the
build — users install Ollama and pull the model (`scripts/download-models.sh`).

## version → build → package → sign → install → migrate → upgrade → rollback
- **version:** workspace version (Cargo) + `PROTOCOL_VERSION` (bump on IPC change). Tag drives release.
- **sign:** macOS notification delivery is unreliable for **unsigned** dev builds — signing matters for
  the meeting/notification feature. Windows toasts are most reliable from an **installed** build whose
  shortcut carries the AUMID `ai.notely.notelyDesktop`.
- **install/upgrade:** app + engine ship together (protocol-locked). A mixed-version pair is rejected
  by the client — so ship both, don't hot-swap one.
- **migrate:** on upgrade, source-of-truth (`notely.db`) needs back-compat/migration; derived DBs
  rebuild (migration, schema-evolution).
- **rollback:** derived DBs are safe to delete; a downgraded app must still read existing `notely.db`
  and vault — preserve back-compat so rollback doesn't strand data.

## Platform readiness reality
macOS is build/test/launch-verified. **Windows/Linux are compile-gated only — not runtime-QA'd.** Run
the on-device QA harness (`docs/meeting-companion.md`) before calling them production-ready.

## Related skills
compatibility-matrix · desktop · overlay · backwards-compatibility · migration · documentation-sync
