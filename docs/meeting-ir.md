# Meeting IR

The **Meeting IR (Intermediate Representation)** is the central abstraction of Notely. It is a
structured description of what happened in a meeting — the stable contract between the reasoning
layer and everything that consumes meeting intelligence.

```text
Transcript
    ↓   (AI: extraction + synthesis)
Meeting IR      ← structured, validated, evidence-linked
    ↓   (deterministic renderer)
MOM (Markdown / HTML / JSON)
```

Defined in `engine/src/domain/meeting_ir.rs`.

## Why the LLM outputs structure, not the final MOM

If the LLM writes the finished Markdown directly, you get prose that is hard to verify, hard to
re-render, and impossible to reuse. Instead the LLM produces **structured data**, and a
deterministic renderer turns it into documents. Benefits:

- **Traceability.** Each fact carries `Evidence` (a transcript span) so the UI can jump to where
  a decision/action was actually said. Users verify instead of trusting blindly.
- **Determinism.** The same IR always renders to the same bytes. No LLM is used merely to format.
- **Reuse.** One IR powers many outputs (Markdown, HTML, JSON) and future consumers (tickets,
  calendar events, search) without re-running the model.
- **Validation.** Structured data can be checked programmatically for consistency and coverage.

## Shape (v0)

Intentionally small for v0; it will grow (topics, questions, risks, timeline) as extraction
supports them.

```json
{
  "title": "Product Planning",
  "summary": "…",
  "participants": [{ "id": "S1", "display_name": "Avadhoot" }],
  "decisions": [
    { "summary": "Ship v0 behind a flag", "evidence": { "start": 610.2, "end": 618.9 } }
  ],
  "action_items": [
    {
      "task": "Complete database migration",
      "owner": "Avadhoot",
      "deadline": "Friday",
      "evidence": { "start": 2612.4, "end": 2621.7 }
    }
  ]
}
```

## Evidence / provenance

`Evidence { start, end }` (seconds) is the unit of traceability. Every extracted decision and
action item can point back into the transcript, which is what makes generated claims checkable.

The IR — not the Markdown — is the thing worth getting right. If the IR is good, the MOM and many
future features follow.
