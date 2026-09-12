# Cross-cutting tests

Repository-level tests that span both the engine and the app, kept separate from each
component's own unit tests (`engine/tests`, `apps/desktop/test`).

- `integration/` — end-to-end flows exercising the engine over IPC (and, where useful,
  the app talking to a real engine).
- `evaluation/` — quality/accuracy evaluation of the AI pipeline (MOM quality, extraction
  accuracy, hallucination checks) against known inputs. Not pass/fail unit tests but
  scored experiments — see `docs/research.md`.
- `fixtures/` — inputs/expected outputs shared across the above. See also
  `data/fixtures/` for sample media/transcripts/IR.

These are scaffolded now and filled in as the pipeline is implemented.
