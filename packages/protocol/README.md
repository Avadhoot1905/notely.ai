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

- **Protocol version:** `1`. Bump on any breaking change; clients refuse mismatched majors.
- **Requests (Flutter → Engine):** `StartMeeting`, `ImportMeeting`, `GetMeeting`,
  `GetTranscript`, `GetMom`, `CancelJob`.
- **Responses (immediate):** `JobAccepted { job_id }`, `Data { json }`, `Error { message }`.
- **Events (Engine → Flutter, async):** `JobCreated`, `TranscriptionStarted`,
  `TranscriptionProgress`, `AnalysisStarted`, `MomGenerated`, `JobCompleted`, `JobFailed`.

## Keeping the two sides in sync

When the protocol changes, update **all three** together:

1. `packages/protocol/schema/` (this contract),
2. `engine/src/ipc/protocol.rs` + `engine/src/ipc/events.rs` (Rust server),
3. `apps/desktop/lib/ipc/protocol.dart` (Dart client),

and bump `PROTOCOL_VERSION` / `protocolVersion` in lockstep.

See `docs/ipc.md` for the boundary's design and lifecycle.
