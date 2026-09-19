---
name: cuda
description: Load when reasoning about NVIDIA/CUDA GPU acceleration on Linux/Windows. The key fact — Notely contains NO CUDA code; GPU acceleration is entirely Ollama's job. Prevents inventing a GPU code path that doesn't exist.
---

# cuda

## The one fact that matters
**No CUDA/FFI/GPU code lives in Notely** (D-0021). GPU acceleration on NVIDIA is **entirely Ollama's
job** — Ollama detects the GPU and uses CUDA automatically. Do not add CUDA bindings, detection, or
memory management to the engine; there is no place for them by design.

## How GPU actually works here
- `NOTELY_LLM_PROVIDER=ollama` (the default on Linux/Windows) → Ollama → CUDA on NVIDIA, CPU otherwise.
- Detection, kernel selection, and VRAM management are all inside Ollama, behind the `LlmProvider`
  HTTP boundary. Notely just sends `generate`/`embed` requests.

## Fallback behavior
No GPU or unsupported GPU → Ollama transparently uses **CPU**; Notely behaves identically, just
slower. Hybrid search, persistent jobs, and the LLM cache are **pure SQLite** and behave the same on
all platforms regardless of GPU.

## Future GPU runtimes
The provider boundary leaves room for a future dedicated GPU runtime (e.g. vLLM) as **just another
`LlmProvider` over HTTP** — same pattern as MLX (see apple-silicon). It would still be a separate
server, never linked in.

## Testing / platforms
Linux/Windows builds are **compile-gated by CI only** (a macOS dev host can't build them locally);
GPU behavior is Ollama's and isn't unit-tested in this repo. Don't claim verified CUDA behavior — see
compatibility-matrix, no-speculation.

## Related skills
ai-runtime · ollama · apple-silicon · compatibility-matrix · no-speculation
