---
name: failure-modes
description: Load when handling errors or reasoning about what can go wrong — a Notely-specific catalog of real failure modes (runtime unavailable, audio device gaps, IPC/version mismatch, SQLite, malformed model output, cancellation) and the expected honest-degradation response for each.
---

# failure-modes

## Catalog (real to this system) → expected behavior
| Failure | Where | Expected response |
|---|---|---|
| **LLM runtime unreachable** (Ollama/MLX down) | `llm/` | Typed `LlmError`; enrichment → `deferred` (retryable), not lost; Ask degrades to passage list. Never crash. |
| **ASR runtime unreachable** | `asr/qwen3_asr.rs` | `AsrError::Unreachable`; audio path errors cleanly. |
| **ASR backend not implemented** (Whisper) | `asr/whisper.rs` | `AsrError::NotImplemented` — honest, not a silent stub. |
| **FFmpeg missing** | `media/ffmpeg.rs` | Clean error on the audio path; transcript input unaffected. |
| **Audio device unavailable / permission denied** | Flutter `MeetingAudioService` | Coherent UI state via `AudioCapabilities`; not a crash. |
| **System audio (loopback) unsupported** | all platforms | Reported `systemAudio: unsupported` with a note — a known gap, not a bug. |
| **Malformed model output** | `ai/extraction.rs`/`synthesis.rs` | `AiError::Parse` → one stricter retry → error. Malformed IR never accepted. |
| **Owner/deadline the model invented** | synthesis reconciliation | Dropped to `null` (anti-invention). |
| **IPC protocol version mismatch** | `ipc/server.rs` / `engine_client.dart` | Hard refusal; client won't talk to a mismatched engine. |
| **IPC transport drop** | `EngineClient` | Reconnect; connection indicator reflects state. |
| **SQLite busy/locked or corrupt derived DB** | `storage/`, derived DBs | Backend error; derived DBs (`search`/`jobs`/`llm_cache`) are rebuildable — `notely.db` is protected. |
| **Job cancelled** | orchestrator | `deferred("cancelled")`, retryable; resources released. |
| **Process dies mid-pipeline** | pipeline | Source intact; `jobs.db` requeues on startup (crash-recovery). |
| **`pactl` absent (Linux detection)** | native runtime | "no detection", not a crash. |
| **Source token missing/invalid** | `sources/` | `SourceError`; token never persisted regardless. |

## Design rule
Notely's stance is **honest degradation, never silent failure and never data loss**. New failure
handling must (a) return a typed error, (b) protect the source of truth, (c) keep the feature
degrading rather than the app crashing, and (d) be surfaced truthfully to the user.

## Related skills
crash-recovery · resource-lifecycle · debugging · offline-first · testing
