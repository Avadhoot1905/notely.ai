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

## Status (v0)

- **Implemented:** the Rust server (`engine/src/ipc/server.rs`), the full request/response/event
  types, versioning, job creation + cancellation, dispatch into the pipeline, and vault-wide
  `Search`/`Ask`. The Dart client (`apps/desktop/lib/ipc`) is a faithful, tested mirror.
- **Transport (v0):** newline-delimited JSON over a loopback **TCP** socket (default
  `127.0.0.1:8765`). Each line is one JSON message. It is *not* an HTTP/web server — just framing.
  The transport is isolated in `server.rs`, so it can change without touching pipeline logic.

## Transport

Isolated behind `ipc::server::Server`. **The pipeline and UI never depend on how bytes move.** On
the wire: client→engine lines are `RequestEnvelope`s; engine→client lines are either a
`ResponseEnvelope` (carries `request_id`) or an `EventEnvelope` (carries `event`).

## Message types

Defined in `engine/src/ipc/protocol.rs` and `events.rs`.

**Requests (Flutter → Engine):**

`Health` · `ProcessMeeting { input }` · `GetJob { job_id }` · `CancelJob { job_id }` ·
`GetMeeting { meeting_id }` · `GetTranscript { meeting_id }` · `GetMom { meeting_id }` ·
`Search { query, vault_path, limit? }` · `Ask { question, vault_path }` · `ListMeetings` ·
`ReprocessMeeting { meeting_id }` · `GetKnowledgeMap { vault_path }` ·
`ListSourceChannels { kind, token, base_url? }` ·
`ImportSource { kind, token, base_url?, vault_path, scope }` · `ListSources` ·
`DisconnectSource { kind, vault_path, remove_imported? }`

`ProcessInput` is either `Transcript { title?, transcript }` (the supported v0 path) or
`Audio { title?, path }` (needs media + ASR — not wired end-to-end yet).

`Search`/`Ask` operate over the user's Markdown vault at `vault_path`: the engine keeps a cheap
incremental FTS5 index of the notes on disk and answers strictly from what it retrieves. `Ask`
returns a source-grounded answer with citations (path + line range + snippet); if the LLM runtime
is unavailable it degrades to a deterministic list of the matching passages rather than failing.

`ListMeetings` returns captured meetings with their durable `ProcessingStatus` (the Inbox).
`ReprocessMeeting` retries AI enrichment for a captured meeting from its stored transcript — the
source is persisted before AI runs, so retry is idempotent and never re-captures or duplicates.

`GetKnowledgeMap` derives the **Knowledge Space** — a deterministic, semantic-topographic model
(regions → concepts → normalized layout) from the same on-disk index, so it costs nothing extra and
stays in step with Search/Ask. The `ListSourceChannels`/`ImportSource`/`ListSources`/
`DisconnectSource` family manages **external knowledge sources** (Slack, Teams): imported messages
are normalized into provenance-bearing Markdown notes under `Imported/<Source>/` in the vault, so
they flow through the *same* index → Search → Ask → citation pipeline. Tokens are passed in-memory
per request and **never persisted** by the engine; only non-secret bookkeeping (what's connected and
imported) is stored.

**Responses (immediate):** `Health(info)` · `JobAccepted { job_id }` · `Job(job)` ·
`Meeting(meeting)` · `Transcript(transcript)` · `Mom { markdown }` ·
`SearchResults([SearchHit])` · `Answer(AskAnswer)` · `MeetingList([MeetingSummary])` ·
`KnowledgeMap(map)` · `SourceChannels { workspace, channels }` · `ImportResult(summary)` ·
`Sources([ConnectedSource])` · `Ok` · `Error { message }`

**Events (Engine → Flutter, async):**

```text
JobCreated
ProcessingStarted
TranscriptionStarted
AnalysisStarted
RenderingStarted
JobCompleted
JobFailed
```

## Lifecycle

```text
Flutter                         Engine
  │  ProcessMeeting{input}          │
  │────────────────────────────────▶│  create job
  │        JobAccepted{job_id}       │
  │◀────────────────────────────────│
  │           JobCreated             │
  │◀───── events (by job_id) ────────│  ProcessingStarted
  │        (Transcription/           │  ... pipeline runs ...
  │         AnalysisStarted/         │
  │         RenderingStarted)        │
  │           JobCompleted           │
```

A request returns quickly (often just a `job_id`); real progress arrives as a stream of events
correlated by `job_id`. `CancelJob` signals cancellation, which the orchestrator checks between
stages.

## IDs and versioning

- **`request_id`** correlates a response with its request.
- **`job_id`** tracks a long-running pipeline run for progress and cancellation.
- **`PROTOCOL_VERSION`** (currently `5`) is sent in every envelope. The client refuses an engine
  with a mismatched major version. (v2 added `Search`/`Ask` + `SearchResults`/`Answer`; v3 added
  `ListMeetings`/`ReprocessMeeting` + `MeetingList` for the Inbox and reliable retry; v4 added
  `GetKnowledgeMap` for the Knowledge Space and the Slack/Teams source family; v5 added
  `TranscribeChunk` for live per-segment ASR, reusing the `Transcript` response.)

## Versioning philosophy

Keep the protocol **small, boring, and explicit**. On any breaking change, update all three of
`packages/protocol`, the Rust side, and the Dart side **together**, and bump the version. Don't
over-design: add message types when a real feature needs them, not speculatively.
