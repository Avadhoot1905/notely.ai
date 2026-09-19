// Domain transcript segment.
//
// The output of ASR (or, today, the mock) — a piece of transcribed speech tied back to a source and
// a span on the meeting timeline. UI-agnostic: widgets project from these via Live Meeting State,
// they never build this from raw audio.

import '../audio/audio_frame.dart' show AudioSource;

/// Whether a transcript piece is still being revised or is settled.
enum TranscriptStatus { partial, finalized }

class TranscriptSegment {
  const TranscriptSegment({
    required this.id,
    required this.start,
    required this.end,
    required this.source,
    required this.text,
    this.speaker,
    this.confidence,
    this.status = TranscriptStatus.finalized,
  });

  final String id;
  final Duration start;
  final Duration end;
  final AudioSource source;

  /// Nullable — diarization is out of scope; a source only hints local (mic) vs remote (system).
  final String? speaker;

  final String text;

  /// Nullable — never fabricated; only set when the ASR engine provides it.
  final double? confidence;

  final TranscriptStatus status;

  TranscriptSegment copyWith({
    String? text,
    TranscriptStatus? status,
    double? confidence,
  }) => TranscriptSegment(
    id: id,
    start: start,
    end: end,
    source: source,
    speaker: speaker,
    text: text ?? this.text,
    confidence: confidence ?? this.confidence,
    status: status ?? this.status,
  );
}
