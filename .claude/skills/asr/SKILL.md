---
name: asr
description: Load when working on speech-to-text — the engine AsrProvider trait (Qwen3-ASR default, Whisper optional) and the Flutter-side AsrEngine seam. Documents that ASR is a SEPARATE runtime from the LLM, current status (Whisper unimplemented; live ASR mocked), and how a real engine slots in.
---

# asr

## The core distinction (D-0013)
ASR is a **separate runtime from the LLM**. Ollama cannot do speech-to-text. So:
- **Qwen3-ASR** (default) runs on its **own HTTP runtime** (`NOTELY_ASR_URL`, default
  `http://localhost:9000`) — not Ollama.
- **Qwen3 1.7B** (understanding) runs on **Ollama**. Different model, different runtime.
Never route ASR through the LLM provider.

## Engine side (`engine/src/asr/`)
- `provider.rs` — `AsrProvider` trait: `name()` + `transcribe(&AudioInput) -> Result<Transcript, AsrError>`.
  `AudioInput { path, language_hint }` (v0 is a path to prepared mono audio; may grow to PCM/segments).
- `qwen3_asr.rs` — HTTP client to the separate Qwen3-ASR runtime (default).
- `whisper.rs` — optional provider behind the same trait; **currently returns `AsrError::NotImplemented`**
  ("honest, not a silent stub"). So `NOTELY_ASR_PROVIDER=whisper` and the audio path end in a clean error.
- Provider selected by `NOTELY_ASR_PROVIDER` (`qwen3-asr` | `whisper` | `fixture`); `fixture` is for tests.
- Errors: `NotImplemented`, `InputNotFound`, `Unreachable` (runtime down), `Runtime`, `Failed`.

## Flutter side (`apps/desktop/lib/services/asr/asr_engine.dart`)
- `AsrEngine` seam: `Stream<TranscriptSegment> transcribe(Stream<SpeechSegment>)`; may emit `partial`
  then `finalized` for the same span if the engine supports incremental results.
- **Intentionally not wired to a real engine yet.** The live UI transcript comes from a mock
  (`MockTranscriptService`) — honest: no ASR is run over captured audio until a real engine exists.
  A real engine (Qwen3-ASR over IPC, or local) implements `AsrEngine` and slots in downstream of
  segmentation, upstream of the meeting event stream.

## Where it fits
Engine: `media → asr → preprocess`. Flutter live: `SpeechSegmenter → AsrEngine → TranscriptSegment
→ MeetingEvent stream → LiveMeetingState`. Language handling is multilingual/code-switched by design.

## Runtime status: set up with `models/manifests/qwen3-asr.yaml`; needed only for the audio path
(transcript input needs no ASR). Verify via `scripts/verify-models.sh`.

## Related skills
audio · ingestion · ai-runtime · meeting-ir · offline-first · testing
