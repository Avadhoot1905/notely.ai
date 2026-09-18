# Development

## Prerequisites

- **Rust** (stable; `rustup`) — see `rust-toolchain.toml`. Includes `rustfmt` + `clippy`.
- **Flutter** (stable, Dart ≥ 3.12) with desktop enabled for your OS.
- **Ollama** — required for AI processing (the **LLM**, default `qwen3:1.7b`). Install from
  <https://ollama.com>, then `ollama pull qwen3:1.7b`.
- **Qwen3-ASR runtime** — only needed for the **audio** input path (transcript input needs no ASR).
  ASR runs on a *separate* HTTP runtime, **not** Ollama (Ollama can't do speech-to-text). See
  `models/manifests/qwen3-asr.yaml`.
- Optional: **FFmpeg** (audio normalization for the audio path), **just** (`justfile`) — otherwise
  use `make` or the scripts directly.

## Configuration

The engine reads these environment variables (all optional; see `.env.example` and
`engine/src/config.rs`):

| Variable | Default | Purpose |
|---|---|---|
| `NOTELY_LLM_PROVIDER` | `ollama` | LLM runtime: `ollama` (cross-platform) \| `mlx` (macOS, opt-in) |
| `NOTELY_OLLAMA_URL` | `http://localhost:11434` | Ollama (LLM) base URL |
| `NOTELY_LLM_MODEL` | `qwen3:1.7b` | LLM model tag (legacy alias: `NOTELY_OLLAMA_MODEL`) |
| `NOTELY_OLLAMA_TIMEOUT_SECS` | `180` | per-generation timeout |
| `NOTELY_MLX_URL` | `http://localhost:8080` | External MLX-LM server URL (used only when provider=`mlx`) |
| `NOTELY_MLX_MODEL` | = `NOTELY_LLM_MODEL` | MLX model tag |
| `NOTELY_MLX_TIMEOUT_SECS` | `180` | MLX per-generation timeout |
| `NOTELY_LLM_MODEL_EXTRACTION` | (runtime default) | Per-task model override for extraction |
| `NOTELY_LLM_MODEL_SYNTHESIS` | (runtime default) | Per-task model override for synthesis |
| `NOTELY_LLM_MODEL_QA` | (runtime default) | Per-task model override for Ask/QA |
| `NOTELY_LLM_MODEL_EMBEDDING` | (unset ⇒ off) | Embedding model; **setting it turns on hybrid search** |
| `NOTELY_ASR_PROVIDER` | `qwen3-asr` | ASR provider: `qwen3-asr` \| `whisper` \| `fixture` |
| `NOTELY_ASR_URL` | `http://localhost:9000` | Qwen3-ASR runtime base URL (separate from Ollama) |
| `NOTELY_ASR_MODEL` | `qwen3-asr` | ASR model id |
| `NOTELY_ASR_TIMEOUT_SECS` | `600` | ASR request timeout |
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
./scripts/download-models.sh   # ollama pull qwen3:1.7b
./scripts/verify-models.sh     # check the LLM (and ASR runtime) are present
```

## End-to-end backend smoke test

Prove the two-pass AI path (transcript → deterministic chunking → Qwen3 1.7B extraction →
synthesis → Meeting IR → Markdown) with a real model. Requires Ollama running with `qwen3:1.7b`:

```bash
# ignored by default so the normal suite never depends on Ollama:
cargo test -p notely-engine --test ollama_smoke -- --ignored --nocapture
# or an interactive runner that prints the IR + MOM:
cargo run -p notely-engine --example transcript_to_mom
# benchmark a larger model without changing the pipeline:
NOTELY_LLM_MODEL=qwen3:4b cargo run -p notely-engine --example transcript_to_mom
```

## Repo conventions

- **Scripts and docs stay flat** (`scripts/`, `docs/`) — no subdirectories for now.
- **One Rust package** (`engine`) — internally modular, not split into crates.
- **IPC changes touch three places** (`packages/protocol`, Rust `ipc`, Dart `ipc`) and bump the
  protocol version.
- Flutter never depends on engine internals — only on the IPC protocol.
