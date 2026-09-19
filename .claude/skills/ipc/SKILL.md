---
name: ipc
description: Load when changing the Flutter↔Rust protocol — the NDJSON-over-loopback-TCP transport, envelope format, request/response/event lifecycle, versioning, and the mandatory three-places update. This is Notely's only backend boundary.
---

# ipc

## The boundary
IPC is the **only** backend boundary (D-0002). Rust: `engine/src/ipc/` (`protocol.rs`, `events.rs`,
`server.rs`). Dart: `apps/desktop/lib/ipc/` (`protocol.dart`, `engine_client.dart`). Canonical spec:
`packages/protocol/`. Everything the app asks the engine to do crosses this line.

## Transport (v0) — D-0011
**Newline-delimited JSON over a loopback TCP socket** (default `127.0.0.1:8765`, `NOTELY_IPC_ADDR`).
Each line is one JSON message. **Not an HTTP/web server — just framing.** Isolated behind
`ipc::server::Server`; the pipeline/UI never depend on how bytes move.

## Wire format
- Client→engine lines: `RequestEnvelope { protocol_version, request_id, request }`.
- Engine→client lines: `ResponseEnvelope { protocol_version, request_id, response }` **or**
  `EventEnvelope { protocol_version, event }`.
- `request_id` correlates a response to its request; `job_id` correlates async events to a run.

## Lifecycle
A request returns quickly (often just `JobAccepted{job_id}`); real progress arrives as an **event
stream correlated by `job_id`** (ProcessingStarted → … → JobCompleted/JobFailed). `CancelJob` signals
cooperative cancellation (checked between stages/chunks — see concurrency). Message surface: api-contracts.

## Versioning (`PROTOCOL_VERSION`)
Currently **`4`** in both `protocol.rs` and `protocol.dart`. Sent in every envelope; the **client
refuses an engine with a mismatched major version** (`engine_client.dart`). History: v2 Search/Ask,
v3 ListMeetings/ReprocessMeeting (Inbox), v4 GetKnowledgeMap + Slack/Teams sources.
*(`docs/ipc.md` prose still says "3" — code is authoritative at 4.)*

## The three-places rule (non-negotiable)
Any protocol change updates **`packages/protocol` + Rust `ipc` + Dart `ipc` together** and **bumps the
version**. The Dart client is a faithful, tested mirror of the Rust types. Keep the protocol small,
boring, explicit — add message types only when a real feature needs them.

## Reconnection / shutdown / errors
Client handles reconnect and the connection indicator (`EngineClient.state`). Request-level failures
return `Response::Error{message}`; pipeline failures surface as `JobFailed` events. Version mismatch is
a hard refusal, not a silent downgrade.

## Tests
`engine/tests/ipc_roundtrip.rs`; Dart `apps/desktop/test/ipc/` (`protocol_test.dart`,
`engine_client_test.dart`). A protocol change without updating both mirrors' tests is incomplete.

## Related skills
api-contracts · backwards-compatibility · schema-evolution · concurrency · debugging · testing
