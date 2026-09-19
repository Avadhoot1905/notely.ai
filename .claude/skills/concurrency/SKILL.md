---
name: concurrency
description: Load when touching async/threaded code in Notely — the Tokio pipeline, job cancellation, IPC event streams, background embedding jobs, or the Dart audio streams and companion's second engine. Documents the actual primitives, ownership, cancellation, and ordering rules.
---

# concurrency

## Engine (Rust / Tokio)
- **Orchestrator** (`pipeline/orchestrator.rs`) runs stages sequentially per job and emits IPC events
  via a `tokio::sync::broadcast` sender. Blocking SQLite calls run on Tokio's blocking pool (D-0009).
- **Cancellation** is cooperative: `CancelFlag` = `Arc<AtomicBool>` (`pipeline/jobs.rs`). The
  orchestrator calls `check_cancel(cancel)?` **between stages and between chunks**. Cancelled work is
  **retryable** — the source is intact, so status becomes `deferred("cancelled")`, not lost.
- **Jobs** are tracked in an in-memory `JobRegistry` mirrored to `jobs.db` (`job_store.rs`): each
  create/transition is persisted so background work survives a crash. Startup requeues `queued`/
  `running` jobs via the idempotent reprocess path, bounded by a small retry budget.
- **Background embedding** is a separate persisted `Embedding` job so it never blocks note saving or
  search; "what needs embedding" is derived from a fingerprint mismatch, so it's self-healing.
- Ordering: IPC events are correlated by `job_id`; a request returns fast, progress arrives async.

## Flutter (Dart / async)
- **`AudioIngestion`** is the capture↔processing boundary: `add()` is **non-blocking** (returns
  immediately, delivery on a microtask) so it never stalls the recorder callback. Buffering is
  **bounded with drop-oldest** overflow and a counted `dropped` — frames are never silently lost.
  Output is a **broadcast** stream (multiple independent consumers). One clock stamps mic + system.
- **Per-source segmenters:** one `SpeechSegmenter` per `AudioSource` — mic and system audio never mix.
- **Companion overlay** runs its **own Flutter engine** (second isolate/engine, `companionMain`) and
  only renders pushed snapshots — no shared mutable state with the main engine. Created once and
  **reused** across show/hide (don't recreate per meeting — that leaks engines/windows/channels).
- Controllers are `ChangeNotifier`; UI folds an event stream into an immutable snapshot rather than
  mutating shared state from multiple producers.

## Rules
- Respect backpressure: keep the bounded-buffer + drop-oldest policy; count drops.
- Check cancellation between units of work in any long engine loop.
- Every stream subscription is owned by its creator and cancelled on teardown (see resource-lifecycle).
- Keep meeting state single-owner (`MeetingSessionManager`); don't add a second concurrent copy.

## Related skills
resource-lifecycle · ingestion · audio · crash-recovery · overlay · ipc
