---
name: audio
description: Load when working on audio capture, framing, buffering, VAD, or speech segmentation — the Flutter-side live-capture seam (AudioFrame → AudioIngestion → VAD → SpeechSegmenter) and the engine's FFmpeg/VAD media stage. Documents ownership, the drop-oldest buffer, and the system-audio gap.
---

# audio

## Two audio worlds
1. **Engine media stage** (`engine/src/media/`: `ffmpeg.rs`, `vad.rs`) — normalizes an imported
   recording to mono for ASR. Part of the (scaffolded) file/audio processing path.
2. **Flutter live-capture seam** (`apps/desktop/lib/services/audio/`) — real-time capture during a
   live meeting. This is the actively-developed area. Seams (each replaceable, single-responsibility):
   - `audio_frame.dart` — `AudioFrame`: PCM16 chunk tagged with `AudioSource` (microphone|system),
     `capturedAt`, sample rate/channels, and a timeline `offset`. **Buffer is immutable and shared**
     (never copied on `withOffset`); never mutate `data` after construction.
   - `meeting_audio_service.dart` — `MeetingAudioService` (impl `RecordMeetingAudioService` over the
     `record` pkg). Emits `AudioFrame`s; reports `AudioCapabilities` **honestly** (a source is
     `capturing` only after real PCM arrives).
   - `audio_ingestion.dart` — capture↔processing boundary/router. Non-blocking `add()`; **bounded
     buffer with drop-oldest + counted `dropped`**; one canonical timeline stamps mic+system; output
     is a broadcast stream.
   - `vad.dart` — `VoiceActivityDetector` seam; `EnergyVad` (RMS threshold ~0.02) is the swappable
     default. **VAD never destroys audio — it only labels frames.**
   - `speech_segmenter.dart` — one `SpeechSegmenter` per source (mic/system never mix). Pre-roll ring
     buffer (no clipped onsets), post-roll hangover (no mid-sentence splits), min-speech (drop blips),
     max-segment cap. Emits `SpeechSegment` (frames + timing + mean energy) for ASR.

## Invariants
- Mic and system audio are kept **distinct all the way to ASR** — never conflated.
- VAD produces information; the segmenter decides — it keeps pre-roll+speech+hangover, drops only
  clearly-silent gaps. No PCM copied until `SpeechSegment.pcm()` is called.
- Capture must never block: `AudioIngestion.add()` returns immediately.

## System audio (loopback) — honest gap
**Not captured on any platform yet.** Reported as `AudioCapabilities.systemAudio = unsupported` with a
per-OS note, not faked. Real loopback needs a native path (macOS ScreenCaptureKit, Windows WASAPI
loopback, Linux PulseAudio/PipeWire monitor), planned in the engine. Don't claim system audio works.

## Tests
`apps/desktop/test/audio/` — `audio_frame_test.dart`, `audio_ingestion_test.dart`,
`vad_segmenter_test.dart`, `system_audio_detection_test.dart`; `integration_test/audio_capture_it_test.dart`.

## Related skills
asr · ingestion · concurrency · resource-lifecycle · desktop · testing
