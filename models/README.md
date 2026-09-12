# Models

This directory holds **model metadata only** — never model weights.

## What lives here

- `manifests/*.yaml` — declarative descriptions of the models Notely uses (name, role,
  provider/runtime, model reference, context length, quantization). These are the source of
  truth for `scripts/download-models.sh` and `scripts/verify-models.sh`, and mirror the
  descriptor in `engine/src/llm/model.rs`.

## Where the actual weights go

Model **weights are never committed to Git.** They are large, license-encumbered, and change
independently of the code. Instead they are downloaded into user/cache locations managed by
the runtime, for example:

- **LLM (Qwen3, …):** stored by the runtime, e.g. Ollama's model store (`ollama pull qwen3`).
- **ASR (Whisper):** downloaded into the ASR backend's model cache.

`.gitignore` is configured so everything under `models/` is ignored **except** this README and
`manifests/`.

## Adding a model

1. Add a manifest under `manifests/`.
2. Ensure the relevant provider in the engine (`engine/src/llm` or `engine/src/asr`) can serve it.
3. Update `scripts/download-models.sh` / `scripts/verify-models.sh` if needed.
