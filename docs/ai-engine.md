# AI engine

Notely separates four concepts that are often conflated. Keeping them distinct is what lets the
system stay model-agnostic and produce traceable output.

```text
┌─────────────────────────────────────────────────────────────┐
│ AI semantic operations   (engine/src/ai)                    │
│   extraction · synthesis · validation                       │
│   works with DOMAIN types, asks for meaning                 │
└───────────────┬─────────────────────────────────────────────┘
                │ asks for generations
                ▼
┌─────────────────────────────────────────────────────────────┐
│ LLM runtime              (engine/src/llm)                   │
│   LlmProvider: generate(request) -> response                │
│   Ollama today; llama.cpp / others later                    │
└───────────────┬─────────────────────────────────────────────┘
                │ runs
                ▼
┌─────────────────────────────────────────────────────────────┐
│ Model / provider         (models/manifests, llm/model.rs)   │
│   Qwen3, Gemma, … — name + settings, weights out-of-repo    │
└─────────────────────────────────────────────────────────────┘

                 all of the above produce / operate on
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Structured Meeting IR    (engine/src/domain/meeting_ir.rs)  │
│   the stable, structured output — NOT prose                 │
└─────────────────────────────────────────────────────────────┘
```

## AI semantic operations (`ai/`)

The reasoning layer. It works with **domain types**, not UI concepts, and is split into:

- **extraction** — pull discrete facts (decisions, action items, participants) out of the
  transcript, each linked to `Evidence` (a transcript time span).
- **synthesis** — compose higher-level understanding (summary, topics) and assemble the IR.
- **validation** — check the IR for consistency and evidence coverage; optionally an LLM
  verification pass.

Crucially, the AI layer **asks for semantic operations**. It does not know or care whether
inference runs through Ollama, llama.cpp, or anything else.

## LLM runtime (`llm/`)

Owns *how* a model is executed, behind `LlmProvider`. Ollama is the v0 target. `provider` (the
runtime) and `model` (which model + settings) are separate concepts so a model can be re-pointed
at a different runtime without touching callers.

## Model / provider

Described by manifests in [`models/`](../models/README.md). **Weights are never in the repo.**

## Why structured IR, not direct MOM

The LLM outputs the **Meeting IR** (structured data), and a deterministic renderer produces the
MOM. This is the core design choice — see [meeting-ir.md](meeting-ir.md).
