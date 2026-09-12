# Models

This directory holds **model metadata only** — never model weights.

## Required runtime

Notely's v0 LLM runtime is **[Ollama](https://ollama.com)** (a local model server). The engine
talks to it over HTTP through the `LlmProvider` abstraction (`engine/src/llm/ollama.rs`); the rest
of the engine never knows Ollama exists.

- Install Ollama and ensure the service is running (`ollama serve`, or the app/brew service).
- Verify: `ollama --version` and `curl http://localhost:11434/api/tags`.

## Selected model (v0 development)

**`qwen3:4b`** (Qwen3, 4B params, `Q4_K_M`, ~2.5 GB) — see `manifests/qwen3.yaml`.

It is the default because it fits a typical dev laptop (Apple Silicon / ~16–24 GB RAM) while
producing usable structured Meeting IR. The engine is model-agnostic: override with the
`NOTELY_OLLAMA_MODEL` env var (e.g. `qwen3:1.7b` for lower-resource machines).

## How to install / pull it

```bash
ollama pull qwen3:4b
# or, using the repo scripts:
./scripts/download-models.sh
./scripts/verify-models.sh
```

## Where the model is actually stored

Weights live in **Ollama's own model store** (e.g. `~/.ollama/models`), **outside this
repository**. The ASR (Whisper) model, once integrated, will likewise live in its backend's cache.

## How Notely accesses it

```text
pipeline → ai (semantic ops) → llm::LlmProvider → OllamaProvider → HTTP → Ollama → Qwen3
```

The AI layer asks for a schema-constrained generation; `OllamaProvider` performs the HTTP call and
requests structured JSON output. The model produces the **Meeting IR**, not the final MOM —
rendering is deterministic and never uses the model.

## What lives here

- `manifests/*.yaml` — declarative descriptions of the models Notely uses (name, family, runtime,
  model tag, context length, quantization, purpose). Source of truth for
  `scripts/download-models.sh` / `scripts/verify-models.sh`, and aligned with the descriptor in
  `engine/src/llm/model.rs`.

## Weights are intentionally NOT committed

Model weights are large, license-encumbered, and change independently of the code. `.gitignore`
ignores everything under `models/` **except** this README and `manifests/`, and also blocks common
weight formats (`*.gguf`, `*.safetensors`, `*.bin`, …) anywhere in the tree. **Never** commit
weights.

## Adding a model

1. Add a manifest under `manifests/`.
2. Ensure the relevant provider (`engine/src/llm` or `engine/src/asr`) can serve it.
3. Update `scripts/download-models.sh` / `scripts/verify-models.sh` if needed.
