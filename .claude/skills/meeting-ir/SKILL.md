---
name: meeting-ir
description: Load when touching the Meeting IR — Notely's central structured contract between the AI layer and everything that consumes meeting intelligence. Covers its shape, Evidence/provenance, ChunkFindings, and why the LLM emits structure (not the final MOM).
---

# meeting-ir

## What it is
The **Meeting IR** (`engine/src/domain/meeting_ir.rs`) is the stable, structured, evidence-linked
description of a meeting. It is the contract between the reasoning layer and every consumer:
```
Transcript → (AI: extraction + synthesis) → Meeting IR → (deterministic renderer) → MOM
```
**The IR — not the Markdown — is the thing worth getting right.**

## Why structure, not prose (D-0005)
The LLM outputs structured data; a deterministic renderer produces documents. This buys
traceability (Evidence spans → jump to where a claim was said), determinism (same IR → same bytes),
reuse (one IR → Markdown/HTML/JSON + future consumers), and programmatic validation. No LLM is ever
used merely to format.

## Shape (v0 — small, designed to grow)
`title`, `summary`, `participants[]` (`id`, `display_name`), `decisions[]`, `action_items[]`
(`task`, `owner?`, `deadline?`, `evidence`), and topics/questions in the renderer. Extend with
optional fields (see schema-evolution); the renderer skips empty sections.

## Evidence / provenance
`Evidence { quote, speaker_id, start, end, chunk_id }` is the unit of traceability. Every decision/
action/topic/question/risk can point back into the transcript. **Evidence is attached
deterministically in Rust** (`ai/extraction.rs`) by matching each item to its source segment — not by
trusting a small model to copy quotes. Items may carry an optional `confidence`.

## ChunkFindings (the layer before the IR)
Extraction first produces `ChunkFindings` per chunk (`ai/findings.rs`) — traceable to a `chunk_id` —
before synthesis consolidates them into the IR. This intermediate layer is what keeps long meetings,
provenance, and debugging tractable:
```
Transcript → chunks → [ChunkFindings per chunk] → synthesis → MeetingIr
```

## Rust owns the schema
`ai/schema.rs` holds the Rust-owned JSON schemas that mirror the domain types. The model fills them
in; it does not define them. Malformed output errors (one stricter retry). Anti-invention rules
(owner/deadline guard, participant backfill) are enforced in Rust — see extraction, synthesis.

## Related skills
extraction · synthesis · ingestion · citations · storage · schema-evolution · ai-runtime
