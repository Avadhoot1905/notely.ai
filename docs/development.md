# Development

## Prerequisites

- **Rust** (stable; `rustup`) — see `rust-toolchain.toml`. Includes `rustfmt` + `clippy`.
- **Flutter** (stable, Dart ≥ 3.12) with desktop enabled for your OS.
- **Ollama** — required for AI processing (the `qwen3:4b` model). Install from
  <https://ollama.com>, then `ollama pull qwen3:4b`.
- Optional: **FFmpeg** (audio extraction; the audio→transcript path is not wired end-to-end yet),
  **just** (`justfile`) — otherwise use `make` or the scripts directly.

## Configuration

The engine reads these environment variables (all optional; see `.env.example` and
`engine/src/config.rs`):

| Variable | Default | Purpose |
|---|---|---|
| `NOTELY_OLLAMA_URL` | `http://localhost:11434` | Ollama base URL |
| `NOTELY_OLLAMA_MODEL` | `qwen3:4b` | model tag to run |
| `NOTELY_OLLAMA_TIMEOUT_SECS` | `120` | per-generation timeout |
| `NOTELY_DATA_DIR` | OS app-data dir | SQLite DB + artifacts location (outside the repo) |
| `NOTELY_LOG_LEVEL` | `info` | `tracing` filter |
| `NOTELY_IPC_ADDR` | `127.0.0.1:8765` | IPC server bind address |

Copy `.env.example` to `.env` (git-ignored) to set these locally.

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
./scripts/download-models.sh   # ollama pull qwen3:4b
./scripts/verify-models.sh     # check required models/runtime are present
```

## End-to-end backend smoke test

Prove the core path (transcript → Ollama/Qwen → structured Meeting IR → Markdown) with a real
model. Requires Ollama running with `qwen3:4b`:

```bash
# ignored by default so the normal suite never depends on Ollama:
cargo test -p notely-engine --test ollama_smoke -- --ignored --nocapture
# or an interactive runner that prints the IR + MOM:
cargo run -p notely-engine --example transcript_to_mom
```

## Repo conventions

- **Scripts and docs stay flat** (`scripts/`, `docs/`) — no subdirectories for now.
- **One Rust package** (`engine`) — internally modular, not split into crates.
- **IPC changes touch three places** (`packages/protocol`, Rust `ipc`, Dart `ipc`) and bump the
  protocol version.
- Flutter never depends on engine internals — only on the IPC protocol.
