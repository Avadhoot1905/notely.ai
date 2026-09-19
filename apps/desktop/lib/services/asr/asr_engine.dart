// ASR seam.
//
// The replaceable boundary between captured audio and transcription. A real engine (Qwen3-ASR over
// the Rust IPC, today) implements [AsrEngine] to turn a captured meeting [AudioRecording] into
// [TranscriptSegment]s. Keeping this an abstraction means `ListeningController` and the UI never see
// Qwen/IPC details — they depend only on this seam.
//
// Two entry points on one seam:
//   - [transcribe]      batch: the whole session recording at stop() — the AUTHORITATIVE transcript.
//   - [transcribeChunk] live:  one closed speech segment mid-session — an ephemeral preview for the
//                              companion, superseded by the batch pass at stop().

import '../audio/audio_frame.dart' show AudioSource;
import '../meeting/transcript_segment.dart';

/// A completed capture handed to ASR: a local audio file plus the metadata needed to place its
/// transcript on the meeting timeline. The file is at an absolute path so the engine (and the
/// separate ASR runtime that reads it) can reach it on the local machine.
class AudioRecording {
  const AudioRecording({
    required this.path,
    required this.source,
    required this.startedAt,
  });

  /// Absolute path to the recorded audio file (WAV).
  final String path;

  /// Which capture source this recording holds (Phase 1: microphone).
  final AudioSource source;

  /// Wall-clock start of the session — the origin of the meeting timeline.
  final DateTime startedAt;
}

/// A single closed speech segment handed to live ASR: a small local audio file plus where it sits on
/// the meeting timeline (so the returned, chunk-relative segment times can be shifted into place).
class AudioChunk {
  const AudioChunk({
    required this.path,
    required this.source,
    required this.offset,
  });

  /// Absolute path to the segment's audio file (WAV).
  final String path;

  /// Which capture source produced the segment.
  final AudioSource source;

  /// The segment's start on the meeting timeline (added to the ASR's chunk-relative times).
  final Duration offset;
}

/// Thrown when transcription cannot run because the backend/ASR runtime is unavailable. Callers
/// surface this as an honest "transcription unavailable" state — never as a crash or a faked result.
class AsrUnavailableException implements Exception {
  const AsrUnavailableException(this.reason);
  final String reason;
  @override
  String toString() => 'AsrUnavailableException: $reason';
}

abstract class AsrEngine {
  /// Transcribe a completed meeting [recording] into ordered, finalized transcript segments (the
  /// authoritative pass at stop()).
  ///
  /// Throws [AsrUnavailableException] when the backend/ASR runtime isn't reachable.
  Future<List<TranscriptSegment>> transcribe(AudioRecording recording);

  /// Transcribe one live speech [chunk] for an immediate companion preview. Best-effort: the caller
  /// treats failures as "no preview" (the batch pass is authoritative). Returned segment times are
  /// already shifted onto the meeting timeline by [AudioChunk.offset].
  Future<List<TranscriptSegment>> transcribeChunk(AudioChunk chunk);
}
