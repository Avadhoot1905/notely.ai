# packages/protocol — the canonical IPC contract

The single, versioned contract for everything the Flutter app asks the engine to do. This directory is
the **canonical spec** (`README.md`, `schema/ipc.schema.json`); both sides mirror it.

## The three-places rule (non-negotiable)
Any change to the protocol updates **all three together**, in one change, with a version bump:
1. `packages/protocol/` (this spec),
2. Rust `engine/src/ipc/` (`protocol.rs`, `events.rs`, `server.rs`),
3. Dart `apps/desktop/lib/ipc/` (`protocol.dart`, `engine_client.dart`).

`PROTOCOL_VERSION` / `protocolVersion` is currently **5** and must be bumped in lockstep. The client
**refuses an engine with a mismatched major version** — so a partial change breaks the app loudly.

## Contract facts
- **Transport:** newline-delimited JSON over loopback **TCP `127.0.0.1:8765`** — framing only, *not* an
  HTTP/web server. Isolated in `engine/src/ipc/server.rs`.
- **Correlation:** `request_id` ties a response to its request; `job_id` correlates async progress
  events to a long-running run. A request returns fast (often just `JobAccepted{job_id}`); progress
  streams as events until `JobCompleted`/`JobFailed`.
- **Degradation is part of the contract** (e.g. `Ask` returns citations even when the LLM is offline).

## Source of truth (resolve the local ambiguity)
This directory's `README.md` calls the schema "the source of truth" but also says the Rust engine
(`engine/src/ipc/`) is. In practice the **implemented Rust `ipc/` is the effective source of truth**;
the schema + Dart client are kept in sync with it. When they disagree, the Rust code wins.

## Conventions
- Keep the protocol **small, boring, explicit**. Add message types only when a real feature needs them —
  not speculatively. The Dart side is a faithful, tested mirror of the Rust types.
- **Version docs are current at `5`** (`README.md`, `docs/ipc.md`, and the Rust/Dart constants all say
  5). If you bump the protocol, update all of them in lockstep — don't let the docs drift behind code.

## Generated / paired files
`schema/ipc.schema.json` is the machine-readable contract — keep it in sync with the Rust/Dart types
(it is not auto-generated from them; update by hand alongside a protocol change).

## Testing
A protocol change is incomplete without updating **both** mirror suites: `engine/tests/ipc_roundtrip.rs`
and `apps/desktop/test/ipc/` (`protocol_test.dart`, `engine_client_test.dart`).

## Related skills
ipc · api-contracts · backwards-compatibility · schema-evolution · concurrency · debugging · testing

## Related modules
`engine/CLAUDE.md` (Rust `ipc/`) · `apps/desktop/CLAUDE.md` (Dart `ipc/`)
