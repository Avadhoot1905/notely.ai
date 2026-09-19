---
name: resource-lifecycle
description: Load when acquiring or releasing resources in Notely — audio devices, streams/subscriptions, files, SQLite connections, HTTP clients to model runtimes, IPC connections, native windows, and the companion's second Flutter engine. Ensures error and cancellation paths release cleanly.
---

# resource-lifecycle

## Resources and their owners
| Resource | Owned by | Release / lifecycle rule |
|---|---|---|
| Microphone / recorder | `RecordMeetingAudioService` (`record` pkg) | `stop()`/`dispose()` closes recorder + stream controllers; report health honestly via `AudioCapabilities`. |
| Audio streams / subscriptions | Whoever subscribes | Cancel the `StreamSubscription` on teardown; `AudioIngestion.dispose()` clears the queue and closes the broadcast controller. |
| Files (vault, artifacts) | engine `storage/` + Flutter `FileSystemService` | Data lives in app-data dir, not the tree; paths via `package:path`. |
| SQLite connections | engine `storage/database.rs` (behind `Store`) | Bundled `rusqlite`; blocking calls on Tokio blocking pool. Derived DBs are rebuildable. |
| HTTP to runtimes (Ollama/MLX/ASR) | `llm/*`, `asr/*` via `reqwest` | Unreachable runtime → typed error / deferral, never a crash. |
| IPC connection | `ipc/server.rs` (engine) / `EngineClient` (Dart) | Loopback TCP; reconnect handled client-side; shutdown closes the socket. |
| Native windows / overlay panel | native runners + `CompanionWindowService` | Panel created once and **reused**; hidden on meeting end/stop; never left stale. |
| Second Flutter engine (companion) | `companionMain` entrypoint | Created once, reused across show/hide — recreating per meeting leaks engines/windows/channels. |
| Job / cancel flag | `JobRegistry` | Terminal states close the job; startup recovery closes unresumable jobs. |

## Rules
1. **Every acquire has a matching release on all paths** — success, error, and cancellation.
2. **Cancellation frees resources:** a cancelled job leaves the source intact and status `deferred`;
   it must not leak a connection, subscription, or window.
3. **Failure degrades, not crashes:** an unreachable runtime, absent `pactl`, or missing FFmpeg
   surfaces a clean error/deferral. This is a repo-wide expectation ("honest, not a silent stub").
4. **Reuse expensive native handles** (companion engine/window) instead of recreating them.
5. **No stale UI state:** the overlay hides on stop; `MeetingSessionManager.start()` hides leftovers.

## Common leaks to check
Uncancelled stream subscriptions; recorder not stopped on error; companion engine recreated per
meeting; a job left `running` without a terminal transition; an HTTP client held past request scope.

## Related skills
concurrency · audio · overlay · storage · crash-recovery · failure-modes
