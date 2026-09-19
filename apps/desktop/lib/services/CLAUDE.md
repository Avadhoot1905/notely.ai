# apps/desktop/lib/services — platform/native seams & live capture

Non-UI logic: the seams where the app meets the OS, native runners, capture hardware, and the engine.
UI (`lib/features/`) depends on these; these never import UI widgets.

## What lives here
- **Platform isolation:** `filesystem/` (`FileSystemService`, `FileWatcherService`, `PathService`),
  `platform/` (`PlatformCapabilities`), `window/`, `notifications/`, `companion/companion_window_service.dart`.
  OS specifics (`Process.run`, FSEvents/inotify, `$HOME`) live here, not in UI.
- **Meeting detection:** `meetings/` (`meeting_detector.dart`, settings) — the honest "mic in use + a
  conferencing app" signal, per-OS behind native `notely/*` channels.
- **Live-capture pipeline:** `audio/`, `asr/`, `meeting/` — actively developed. Data flow:
  `AudioFrame` → `AudioIngestion` (router) → `SpeechSegmenter` (per source, using a `VoiceActivityDetector`)
  → `AsrEngine` → `TranscriptSegment` → `MeetingEvent` stream → `LiveMeetingState` (UI projection).

## Live-capture invariants (non-obvious — preserve them)
- **Mic and system audio stay distinct all the way to ASR** — one `SpeechSegmenter` per `AudioSource`;
  never mix sources.
- **VAD never destroys audio** — it only labels frames; the segmenter keeps pre-roll + speech + hangover
  and drops only clearly-silent gaps. No PCM is copied until `SpeechSegment.pcm()`.
- **Capture must never block:** `AudioIngestion.add()` returns immediately; buffering is **bounded with
  drop-oldest + a counted `dropped`** — frames are never silently lost.
- `AudioFrame.data` is **immutable and shared** (never copied on `withOffset`); never mutate it.
- **ASR is currently mocked** (`AsrEngine` seam; live transcript from `MockTranscriptService`) — honest:
  no ASR runs over captured audio until a real engine (Qwen3-ASR over IPC) implements the seam.
- **System audio (loopback) is unsupported on all platforms** — reported via `AudioCapabilities`, not
  faked. Don't claim it works.

## Ownership / boundary
- **`MeetingSessionManager` (in `lib/features/meetings/`) is the single source of truth** for meeting
  state; both the main window and the overlay observe the *same* instance. The **overlay is
  presentation-only** — do NOT give it its own ingestion/ASR/storage/IPC path or a second copy of state.
- The companion window runs its own Flutter engine and renders **pushed snapshots** only; it is created
  once and **reused** across show/hide (recreating per meeting leaks engines/windows/channels).
- Native `notely/*` channels have four implementations (`macos/`, `windows/`, `linux/` runners + Dart);
  a channel name or payload-key change must be applied to **all four**.

## Testing
`test/audio/` (`audio_frame_test`, `audio_ingestion_test`, `vad_segmenter_test`,
`system_audio_detection_test`), `test/meeting_*`, `test/session_test`,
`integration_test/audio_capture_it_test.dart`. Test the Dart capability/fallback logic, not native GUI.

## Related skills
audio · asr · overlay · desktop · concurrency · resource-lifecycle · flutter-ui · testing

## Related modules
`apps/desktop/CLAUDE.md` · `engine/CLAUDE.md` (real ASR lives behind the engine `asr/` trait)
