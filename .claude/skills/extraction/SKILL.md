---
name: extraction
description: Load when working on the first AI pass — per-chunk extraction of decisions/action items/participants into ChunkFindings, with deterministic Rust evidence grounding. Covers the schema-constrained call, provenance attachment, and anti-invention guards.
---

# extraction

## Role
The **first** of two deliberately separate LLM passes (`engine/src/ai/extraction.rs`). One
schema-constrained call **per prepared chunk** → `ChunkFindings` (`ai/findings.rs`). Findings are
kept separate from the final IR so long meetings, provenance, and debugging stay tractable.

## Contract
`AiAnalyzer::extract_chunk(chunk: &Chunk, ctx: &AnalysisContext) -> Result<ChunkFindings, AiError>`.
Uses `LlmProvider::generate` with `ai/schema.rs` as the `format` (structured output). Low temperature
suits extraction. It never speaks HTTP to Ollama directly — it asks `llm/` for a generation.

## Deterministic evidence grounding (Rust, not the model) — D-0016
Small models unreliably copy quotes and miss owners/deadlines, so Rust does the trustworthy work:
- Each finding is matched back to its **source transcript segment**; Rust attaches the real `quote` +
  precise timestamps + `speaker_id` + `chunk_id`. Quotes the model *did* copy are kept and back-stamped.
- **Participants come from the transcript speakers**, not the model (backfill happens in synthesis).
This is what makes claims checkable in the UI. Don't move provenance into the prompt/model.

## Anti-invention
The model may surface candidate decisions/actions, but Rust decides what survives with evidence.
Owner/deadline enforcement happens in synthesis reconciliation (see synthesis) — extraction's job is
faithful, grounded findings per chunk.

## Errors & repair
`AiError::Parse` on non-JSON output triggers **one stricter retry** before erroring; malformed output
is never accepted as valid findings. `AiError::Llm` wraps runtime failures.

## Progress
The orchestrator drives extraction per chunk and emits `ExtractionStarted{n}` →
`ExtractionProgress{i/n}` → `ExtractionCompleted` (real progress, never faked).

## Related skills
synthesis · meeting-ir · ai-runtime · ingestion · testing
