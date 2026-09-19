---
name: api-contracts
description: Load when changing or relying on a contract between Notely's layers — the IPC Request/Response/Event protocol, or the AsrProvider/AiAnalyzer/LlmProvider/Store traits. Documents inputs, outputs, errors, ownership, and the three-places rule.
---

# api-contracts

## The contracts that matter
1. **IPC** (`engine/src/ipc/protocol.rs` + `events.rs`; Dart mirror `apps/desktop/lib/ipc/protocol.dart`;
   canonical spec `packages/protocol/`). `PROTOCOL_VERSION = 4`.
2. **Engine traits** — the pipeline depends on these, never on concrete backends:
   `AsrProvider`, `AiAnalyzer`, `LlmProvider`, `Store`, plus deterministic helpers
   (`preprocess::prepare`, `renderer::markdown`).

## IPC message surface (verify in `protocol.rs`)
- **Requests:** `Health` · `ProcessMeeting{input}` · `GetJob` · `CancelJob` · `GetMeeting` ·
  `GetTranscript` · `GetMom` · `Search{query,vault_path,limit?}` · `Ask{question,vault_path}` ·
  `ListMeetings` · `ReprocessMeeting` · `GetKnowledgeMap` · `ListSourceChannels` · `ImportSource` ·
  `ListSources` · `DisconnectSource`. `ProcessInput` = `Transcript{title?,transcript}` (supported) or
  `Audio{title?,path}` (not wired end-to-end).
- **Responses (immediate):** `Health` · `JobAccepted{job_id}` · `Job` · `Meeting` · `Transcript` ·
  `Mom{markdown}` · `SearchResults` · `Answer` · `MeetingList` · `KnowledgeMap` · `SourceChannels` ·
  `ImportResult` · `Sources` · `Ok` · `Error{message}`.
- **Events (async, by `job_id`):** `JobCreated` · `ProcessingStarted` · media/transcription/chunking/
  extraction(+progress)/synthesis/validation/rendering start-complete · `JobCompleted`/`JobFailed`
  (see `events.rs`; granular where measurable, never faked).

## Contract semantics
- **Correlation:** `request_id` ties a response to its request; `job_id` tracks a long run for
  progress + cancellation. A request returns fast (often just `job_id`); progress streams as events.
- **Errors:** engine returns `Response::Error{message}` for request-level failures; pipeline failures
  surface as `JobFailed` events. Each engine module has its own `thiserror` enum internally.
- **Degradation is part of the contract:** `Ask` never hard-fails — on LLM error it returns a
  deterministic list of matching passages with citations (see citations, offline-first).
- **Ownership:** the app owns `request_id`; the engine owns `job_id` and event ordering. Tokens in
  `ImportSource`/`ListSourceChannels` are passed in-memory per request and **never persisted**.

## The three-places rule (non-negotiable)
Any breaking IPC change updates **all three** — `packages/protocol`, Rust `ipc`, Dart `ipc` —
**together**, and bumps the version. The client refuses an engine with a mismatched major version.
Add message types only when a real feature needs them (versioning philosophy in `docs/ipc.md`).

## Trait contracts (engine)
- `LlmProvider`: `generate`/`health`/`embed` (`embed` defaults to `Unsupported`; callers degrade).
- `AsrProvider`: `name` + `transcribe(&AudioInput) -> Transcript`; `AudioInput{path, language_hint}`.
- `AiAnalyzer`: `extract_chunk(chunk, ctx) -> ChunkFindings` then `synthesize(findings, transcript,
  ctx) -> MeetingIr`. Two passes are the contract — don't collapse.
- `Store`: domain-in/domain-out save/get for meeting, transcript, IR, MOM, processing status.

## Related skills
ipc · schema-evolution · backwards-compatibility · ai-runtime · storage · testing
