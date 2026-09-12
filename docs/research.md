# Research

Notes and open questions to be answered **experimentally**, not assumed. Evaluation harnesses and
datasets live under [`tests/evaluation`](../tests/README.md); sample inputs under
[`data/fixtures`](../data/fixtures/README.md).

## Open questions

1. How much better is Qwen3 vs. Gemma 3 on real multilingual meeting transcripts?
2. What is the smallest model that produces reliable Meeting IR?
3. How much does a verification pass improve factual accuracy (fast vs. verified mode)?
4. Can one LLM efficiently do extraction, verification, and generation?
5. How should long meetings be chunked?
6. How should speaker diarization interact with ASR?
7. How should evidence be represented and surfaced in the UI?
8. What exactly belongs in the Meeting IR?
9. When is a database actually necessary (vs. plain files)?
10. What is the minimum hardware for a good local experience?

## ASR experiments

- Whisper checkpoints (see `models/manifests/whisper.yaml`): quality vs. speed vs. memory.
- Multilingual / code-switched accuracy (English + Hindi + Marathi + Hinglish + technical terms).
- Diarization approach and how it attaches speakers to transcript segments.

## LLM / reasoning experiments

- Qwen3 vs. Gemma on extraction quality and IR validity.
- Prompt strategies for extraction vs. synthesis vs. validation.
- Structured-output reliability (does the model reliably produce valid IR JSON?).

## Prior art to learn from

Meetily (local capture, diarization, Ollama), Mityu (source-linked, verifiable output), Hyprnote
(human notes as context), clawd-scribe (tiny stack), Sard (separate models/providers/logic),
Murmur (single-command UX), Squirrel Notes (don't over-engineer v0).

## Method

Prefer measured experiments with fixtures and scored evaluation over speculation. Record findings
here and promote stable conclusions into [decisions.md](decisions.md).
