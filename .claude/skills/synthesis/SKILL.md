---
name: synthesis
description: Load when working on the second AI pass — consolidating per-chunk ChunkFindings into the Meeting IR, with deterministic Rust reconciliation (dedup/merge, owner/deadline guard, participant backfill). Covers why extraction and synthesis stay separate.
---

# synthesis

## Role
The **second** of two deliberately separate LLM passes (`engine/src/ai/synthesis.rs`). One call
consolidates all `ChunkFindings` → `MeetingIr` (dedup/merge + overall summary/topics), followed by
**deterministic reconciliation in Rust**.

## Contract
`AiAnalyzer::synthesize(findings: &[ChunkFindings], transcript: &Transcript, ctx: &AnalysisContext)
-> Result<MeetingIr, AiError>`. `transcript` is the normalized transcript, used for participant
backfill and provenance reconciliation.

## Deterministic reconciliation (Rust, after the LLM)
- **Owner/deadline guard:** an owner or deadline is kept **only if** a source finding stated it or it
  appears verbatim in the transcript — otherwise dropped to `null`. The model may **not** invent
  people or dates.
- **Participant backfill:** participants come from transcript speakers, not the model.
- **Evidence reconciliation:** merged items keep their grounded `Evidence` from extraction.

## Why two passes (never collapse) — D-0015
Splitting extraction (per chunk) from synthesis (global) buys long-meeting scalability, provenance,
easier evaluation, and lets chunking change independently of prompts. We never do
`transcript → LLM → MOM`.

## Validation
After synthesis, `ai/validation.rs` runs deterministic structural checks (consistency, evidence
coverage); an optional LLM verification pass is scaffolded/planned (fast vs verified mode). Malformed
IR is never accepted — one stricter retry on parse failure, then error.

## Progress
Orchestrator emits `SynthesisStarted/Completed` then `ValidationStarted/Completed`.

## Related skills
extraction · meeting-ir · ai-runtime · ingestion · testing
