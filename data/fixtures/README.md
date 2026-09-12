# Fixtures

Small, checked-in sample data used by tests and manual experimentation.

- `audio/` — short sample audio clips. **Large/binary audio is git-ignored** (see
  `.gitignore`); keep only tiny clips needed by tests, or generate them on demand.
- `transcripts/` — canonical transcript JSON samples (the ASR-stage contract).
- `meeting_ir/` — sample Meeting IR JSON documents (the AI-stage output / renderer input).

Keep fixtures small and representative. Real meeting data must never be committed.
