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

## The contract (v1)

This matches the implemented Rust engine (`engine/src/ipc/`). The Dart client
(`apps/desktop/lib/ipc`) is scaffolded against an earlier draft and will be re-synced.

- **Protocol version:** `1`. Bump on any breaking change; clients refuse mismatched majors.
- **Transport (v0):** newline-delimited JSON over a loopback TCP socket (default
  `127.0.0.1:8765`), isolated in `server.rs` so it can change later.
- **Requests (Flutter → Engine):** `Health`, `ProcessMeeting { input }`, `GetJob { job_id }`,
  `CancelJob { job_id }`, `GetMeeting { meeting_id }`, `GetTranscript { meeting_id }`,
  `GetMom { meeting_id }`. `input` is `Transcript { title?, transcript }` or
  `Audio { title?, path }`.
- **Responses (immediate):** `Health(info)`, `JobAccepted { job_id }`, `Job(job)`,
  `Meeting(meeting)`, `Transcript(transcript)`, `Mom { markdown }`, `Error { message }`.
- **Events (Engine → Flutter, async):** `JobCreated`, `ProcessingStarted`, `TranscriptionStarted`,
  `AnalysisStarted`, `RenderingStarted`, `JobCompleted`, `JobFailed`.

## Keeping the two sides in sync

When the protocol changes, update **all three** together:

1. `packages/protocol/schema/` (this contract),
2. `engine/src/ipc/protocol.rs` + `engine/src/ipc/events.rs` (Rust server),
3. `apps/desktop/lib/ipc/protocol.dart` (Dart client),

and bump `PROTOCOL_VERSION` / `protocolVersion` in lockstep.

See `docs/ipc.md` for the boundary's design and lifecycle.
