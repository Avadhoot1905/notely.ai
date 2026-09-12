# Development

## Prerequisites

- **Rust** (stable; `rustup`) — see `rust-toolchain.toml`. Includes `rustfmt` + `clippy`.
- **Flutter** (stable, Dart ≥ 3.12) with desktop enabled for your OS.
- Optional runtimes for real processing: **Ollama** (local LLM), **FFmpeg**, a Whisper backend.
- Optional: **just** (`justfile`) — otherwise use `make` or the scripts directly.

## First-time setup

```bash
./scripts/bootstrap.sh      # verify toolchains, fetch Rust + Flutter deps
```

## Running

```bash
./scripts/start-engine.sh    # run the Rust engine        (cargo run -p notely-engine)
./scripts/start-desktop.sh   # run the Flutter desktop app (flutter run)
./scripts/dev.sh             # engine + desktop together
```

or via `make dev` / `just dev`.

## Checks, tests, build

```bash
./scripts/check.sh    # cargo fmt --check + clippy; dart format check + flutter analyze
./scripts/test.sh     # cargo test + flutter test
./scripts/build.sh    # release build of engine + desktop app
```

### Running the underlying tools directly

```bash
# Engine (Rust)
cargo fmt --check
cargo check
cargo clippy --all-targets -- -D warnings
cargo test

# Desktop (Flutter) — from apps/desktop/
flutter pub get
dart format lib test integration_test
flutter analyze
flutter test
flutter test integration_test    # integration tests
```

## Models

Model weights are **not** in the repo. Manifests live in `models/manifests/`.

```bash
./scripts/download-models.sh   # pull models into runtime/cache (e.g. `ollama pull qwen3`)
./scripts/verify-models.sh     # check required models are present
```

## Repo conventions

- **Scripts and docs stay flat** (`scripts/`, `docs/`) — no subdirectories for now.
- **One Rust package** (`engine`) — internally modular, not split into crates.
- **IPC changes touch three places** (`packages/protocol`, Rust `ipc`, Dart `ipc`) and bump the
  protocol version.
- Flutter never depends on engine internals — only on the IPC protocol.
