# packages/protocol

The **canonical IPC contract** shared between the Dart client and the Rust engine.

This is **not a backend** and contains **no application logic**. It exists so the two
implementations stay in sync:

```text
                 packages/protocol
                       │
              ┌────────┴────────┐
              ▼                 ▼
           Flutter             Rust
           client              server
   apps/desktop/lib/ipc     engine/src/ipc
```

## Contents

- `schema/` — language-neutral schema definitions for the IPC messages (requests, responses,
  events) plus the protocol version. Treat these as the source of truth.

## The contract (v2)

This matches the implemented Rust engine (`engine/src/ipc/`, the source of truth). The Dart client
(`apps/desktop/lib/ipc`) is synced to this contract: a real `EngineClient` speaks the transport
below, and `protocol.dart` mirrors these types.

- **Protocol version:** `2`. Bump on any breaking change; clients refuse mismatched majors.
  (v2 added vault-wide `Search`/`Ask` and their `SearchResults`/`Answer` responses.)
- **Transport (v0):** newline-delimited JSON over a loopback TCP socket (default
  `127.0.0.1:8765`), isolated in `server.rs` so it can change later. The engine runs as a
  separate process; the app connects and reconnects with capped backoff.
- **Envelopes:** requests → `{ protocol_version, request_id, type, params? }`; responses →
  `{ protocol_version, request_id, type, data }`; events → `{ protocol_version, event: { type, data } }`.
  A client distinguishes a response (has `request_id`) from an event (has `event`).
- **Requests (Flutter → Engine):** `Health`, `ProcessMeeting { input }`, `GetJob { job_id }`,
  `CancelJob { job_id }`, `GetMeeting { meeting_id }`, `GetTranscript { meeting_id }`,
  `GetMom { meeting_id }`, `Search { query, vault_path, limit? }`, `Ask { question, vault_path }`.
  `input` is `Transcript { title?, transcript }` or `Audio { title?, path }`. `Search`/`Ask` run
  over the user's Markdown vault at `vault_path` (an incremental FTS5 index the engine keeps of the
  notes on disk).
- **Responses (immediate):** `Health(info)`, `JobAccepted { job_id }`, `Job(job)`,
  `Meeting(meeting)`, `Transcript(transcript)`, `Mom { markdown }`,
  `SearchResults([SearchHit])`, `Answer(AskAnswer)`, `Error { message }`. A `SearchHit` is
  `{ path, title, start_line, end_line, snippet }`; an `AskAnswer` is
  `{ text, files_read, citations: [{ path, start_line, end_line, snippet }] }` where `text` may
  contain `[n]` markers referencing the citations.
- **Events (Engine → Flutter, async):** `JobCreated`, `ProcessingStarted`,
  `MediaProcessingStarted`/`MediaProcessingCompleted`,
  `TranscriptionStarted`/`TranscriptionProgress`/`TranscriptionCompleted`,
  `ChunkingStarted`/`ChunkingCompleted`,
  `ExtractionStarted`/`ExtractionProgress`/`ExtractionCompleted`,
  `SynthesisStarted`/`SynthesisCompleted`, `ValidationStarted`/`ValidationCompleted`,
  `RenderingStarted`/`RenderingCompleted`, `JobCompleted`, `JobFailed`. Every event's `data`
  carries the `job_id` it belongs to.

## Keeping the two sides in sync

When the protocol changes, update **all three** together:

1. `packages/protocol/schema/` (this contract),
2. `engine/src/ipc/protocol.rs` + `engine/src/ipc/events.rs` (Rust server),
3. `apps/desktop/lib/ipc/protocol.dart` (Dart client),

and bump `PROTOCOL_VERSION` / `protocolVersion` in lockstep.

See `docs/ipc.md` for the boundary's design and lifecycle.
