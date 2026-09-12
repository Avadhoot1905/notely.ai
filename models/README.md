# Models

This directory holds **model metadata only** — never model weights.

## Two models, two runtimes

Notely uses **two Qwen models on two different runtimes** (see `docs/ai-engine.md`):

| Model | Task | Runtime | Manifest |
|-------|------|---------|----------|
| **Qwen3 1.7B** | meeting understanding (extraction + synthesis) | **Ollama** | `manifests/qwen3.yaml` |
| **Qwen3-ASR** | speech recognition | **separate ASR runtime (HTTP)** — *not* Ollama | `manifests/qwen3-asr.yaml` |

**Ollama does not do speech-to-text**, so ASR is a genuinely separate runtime. Do not try to serve
Qwen3-ASR through Ollama.

## LLM runtime — Ollama

- Install [Ollama](https://ollama.com) and ensure it's running (`ollama serve`, or the brew/app service).
- Verify: `ollama --version` and `curl http://localhost:11434/api/tags`.

### Selected LLM (v0 default): `qwen3:1.7b`

Qwen3 1.7B (`Q4_K_M`, ~1.4 GB) — small enough that extraction + synthesis run comfortably on a dev
laptop. The engine is model-agnostic: override with `NOTELY_LLM_MODEL` (e.g. `qwen3:4b` or
`qwen3:0.6b`) to benchmark without changing the pipeline.

```bash
ollama pull qwen3:1.7b
# or, using the repo scripts:
./scripts/download-models.sh
./scripts/verify-models.sh
```

## ASR runtime — Qwen3-ASR (separate)

Qwen3-ASR runs on its own local inference server exposing an HTTP endpoint; the engine reaches it
via `Qwen3AsrProvider` (`engine/src/asr/qwen3_asr.rs`), configured with `NOTELY_ASR_URL`. No
open-weights Qwen3-ASR is bundled — provide your own runtime. The **transcript-first** path needs
no ASR at all. Whisper remains an optional fallback provider (`NOTELY_ASR_PROVIDER=whisper`).

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
