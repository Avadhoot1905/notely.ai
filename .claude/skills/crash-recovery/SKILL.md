---
name: crash-recovery
description: Load when working on durability, restart behavior, or the job queue — what Notely guarantees if the process dies during recording, ASR, extraction, synthesis, persistence, or indexing, and where the real gaps are. Anchored on "AI failure ≠ data loss".
---

# crash-recovery

## The core guarantee: "AI failure ≠ data loss"
The **source (meeting + transcript) is persisted to `notely.db` before any AI runs**, and enrichment
`processing_status` is a **separate artifact**. So a crash or failure during enrichment never loses
the capture — it's marked `deferred` and is retryable (storage, reliability).

## Durable jobs + startup recovery (D-0018)
The in-memory `JobRegistry` is mirrored to `jobs.db` (`pipeline/job_store.rs`): **every create and
state transition is persisted**. On startup the engine **requeues** any job left `queued`/`running`
when the process died, resuming via the **idempotent reprocess path** (the source transcript is
already safe), bounded by a **small retry budget**. A job with no resumable transcript is **closed,
not looped**. Not a distributed queue — one local table.

## What happens if the process dies during…
| Phase | Outcome |
|---|---|
| **Recording / live capture (Flutter)** | Live-capture state is in-memory; a session interrupted mid-record is **not** auto-recovered (documented gap — see meeting-companion QA). No engine data lost because live ASR isn't persisting meetings yet. |
| **Media/ASR** (audio path) | Audio path is scaffolded; nothing enriched. No partial meeting persisted. |
| **Extraction / synthesis** | Source transcript already saved → job requeued on startup; reprocess is idempotent (no duplicate/re-capture). |
| **Persistence** (writing IR/MOM) | Source + status protect against loss; on restart the job re-runs enrichment from the transcript. |
| **Indexing / embedding** | `search.db` is derived; embedding is a persisted background job resumed via fingerprint mismatch — self-healing (search). |

## Rules for new work
- Persist the **source before** any lossy/expensive step; keep status separate.
- Make any new pipeline step **idempotent** w.r.t. reprocess/requeue (no duplicate captures).
- Bound retries; close unresumable work — never spin.
- Don't put a source of truth in a derived DB.

## Known gaps (don't claim otherwise)
Full **live-meeting session recovery** across an app restart mid-meeting is **not implemented**
(documented in meeting-companion). Windows/Linux background lifecycle lacks a relaunch tray.

## Related skills
storage · concurrency · resource-lifecycle · failure-modes · backwards-compatibility · testing
