# IPC

IPC is the **primary (and for v0, only) backend boundary**. Everything the app can ask the
engine to do crosses this line as a small, versioned, serializable message.

```text
Flutter ──request──▶  IPC  ──▶ Engine
Flutter ◀──event────  IPC  ◀── Engine
```

- Rust side: `engine/src/ipc/` (`protocol.rs`, `events.rs`, `server.rs`).
- Dart side: `apps/desktop/lib/ipc/` (`protocol.dart`, `engine_client.dart`).
- Canonical contract: [`packages/protocol`](../packages/protocol/README.md).

## Transport

The transport (local socket, stdio pipe to the engine process, …) is chosen per platform and
kept behind `ipc::server::Server` / `EngineClient`. **The pipeline and UI never depend on how
bytes move** — so we can change transports later without rewriting either side.

## Message types

**Requests (Flutter → Engine)** — deliberately minimal for v0:

`StartMeeting` · `ImportMeeting` · `GetMeeting` · `GetTranscript` · `GetMom` · `CancelJob`

**Responses (immediate):** `JobAccepted { job_id }` · `Data { json }` · `Error { message }`

**Events (Engine → Flutter, async):**

```text
JOB_CREATED
TRANSCRIPTION_STARTED
TRANSCRIPTION_PROGRESS
ANALYSIS_STARTED
MOM_GENERATED
JOB_COMPLETED
JOB_FAILED
```

## Lifecycle

```text
Flutter                         Engine
  │  StartMeeting/ImportMeeting     │
  │────────────────────────────────▶│  create job
  │        JobAccepted{job_id}       │
  │◀────────────────────────────────│
  │           JOB_CREATED            │
  │◀───── events (by job_id) ────────│  TRANSCRIPTION_STARTED
  │        TRANSCRIPTION_PROGRESS     │  ... pipeline runs ...
  │           ANALYSIS_STARTED       │
  │           MOM_GENERATED          │
  │           JOB_COMPLETED          │
```

A request returns quickly (often just a `job_id`); real progress arrives as a stream of events
correlated by `job_id`. `CancelJob` signals cancellation to the running job.

## IDs and versioning

- **`request_id`** correlates a response with its request.
- **`job_id`** tracks a long-running pipeline run for progress and cancellation.
- **`PROTOCOL_VERSION`** (currently `1`) is sent in every envelope. The client refuses an engine
  with a mismatched major version.

## Versioning philosophy

Keep the protocol **small, boring, and explicit**. On any breaking change, update all three of
`packages/protocol`, the Rust side, and the Dart side **together**, and bump the version. Don't
over-design: add message types when a real feature needs them, not speculatively.
