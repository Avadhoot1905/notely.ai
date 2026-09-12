# Product

## What Notely is

An open-source, **local-first** meeting intelligence app that turns multilingual conversations
into structured, evidence-backed Minutes of Meeting (MOM) — without sending meetings to the cloud.

No mandatory cloud service. No API key. No subscription.

## The problem

Most AI meeting assistants send audio to cloud transcription and a cloud LLM. That brings privacy
risk, recurring cost, vendor lock-in, weak support for local/mixed-language meetings, and little
visibility into where an AI claim came from.

## v0 goal

> **Can we turn a meeting recording into a genuinely useful MOM, entirely locally?**

That is the whole bet for v0.

## v0 scope

**In:**
- Desktop app (macOS/Windows) over a local Rust engine.
- Import an existing recording (and, later, record) → transcript → **Meeting IR** → MOM.
- Local ASR (Whisper) and local LLM (Qwen via Ollama).
- Structured extraction of decisions and action items with **evidence** back to the transcript.
- Deterministic MOM rendering (Markdown/HTML/JSON).
- Multilingual / code-switched meetings treated as normal.

**Out (for now):**
- Zoom/Teams competitor, SaaS, real-time collaboration, enterprise RBAC.
- Calendar/task integrations, knowledge graph, multi-agent frameworks.

## Guiding principle

> Don't build an AI that writes meeting notes. Build a local system that **understands** meetings.

The MOM is simply the first useful representation of that understanding. If the underlying
[Meeting IR](meeting-ir.md) is good, the same data can later power action items, project updates,
tickets, search, and more.

## Longer-term direction

A local meeting-intelligence engine other applications can build on — the engine is deliberately
decoupled from the UI via IPC so future frontends/consumers can reuse it. See the roadmap in the
root [README](../README.md).
