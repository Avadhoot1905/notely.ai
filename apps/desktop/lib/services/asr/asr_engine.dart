// ASR seam.
//
// The replaceable boundary between speech segmentation and transcription. A real engine (Qwen3-ASR
// over the Rust IPC, or a local model) implements [AsrEngine] to turn [SpeechSegment]s into
// [TranscriptSegment]s. It is intentionally NOT wired to a live engine yet: today the app's live
// transcript comes from the mock (see MockTranscriptService), which is honest — we do not run ASR
// over captured audio until a real engine exists. This interface is the extension point where it
// slots in, downstream of segmentation and upstream of the meeting event stream.

import '../audio/speech_segmenter.dart';
import '../meeting/transcript_segment.dart';

abstract class AsrEngine {
  /// Transcribe a stream of speech segments into transcript segments. May emit `partial` then
  /// `finalized` for the same span if the engine supports incremental results.
  Stream<TranscriptSegment> transcribe(Stream<SpeechSegment> segments);
}
