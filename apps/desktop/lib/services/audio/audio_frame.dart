// Source-aware captured-audio contract.
//
// The smallest domain object that flows out of capture: a chunk of PCM tagged with WHICH source
// produced it and WHEN, plus the format needed to interpret the bytes. It is intentionally free of
// any Flutter/UI or ASR coupling so every downstream layer (ingestion, VAD, segmentation, ASR) can
// depend on it without depending on each other.
//
// Buffer ownership: [data] is owned by the frame and MUST NOT be mutated after construction. It is
// handed off from the recorder callback (not copied), so treat it as immutable. [withOffset] returns
// a new frame that SHARES the same [data] buffer — no PCM is copied when the meeting timeline is
// stamped on during ingestion.

import 'dart:typed_data';

/// Which capture source a frame came from. Kept distinct all the way to ASR so microphone (local
/// participant) and system audio (remote participants) are never conflated.
enum AudioSource { microphone, system }

/// PCM sample format. Only 16-bit little-endian PCM is produced today (see the `record` config).
enum AudioFormat { pcm16 }

/// One chunk of captured PCM with its source, timing, and format.
class AudioFrame {
  const AudioFrame({
    required this.source,
    required this.capturedAt,
    required this.sampleRate,
    required this.channels,
    required this.data,
    this.format = AudioFormat.pcm16,
    this.offset,
  });

  /// Which source produced this frame.
  final AudioSource source;

  /// Wall-clock time the frame was received from the recorder callback.
  final DateTime capturedAt;

  /// Position on the canonical meeting timeline (from session start). `null` until an
  /// [AudioIngestion] stamps it — capture doesn't know the meeting's start instant.
  final Duration? offset;

  final int sampleRate;
  final int channels;
  final AudioFormat format;

  /// Immutable PCM payload (16-bit LE). Owned by this frame; never mutated. Shared by [withOffset].
  final Uint8List data;

  int get bytesPerSample => 2; // pcm16

  /// Number of sample frames (per-channel samples) in this chunk.
  int get frameCount {
    if (channels <= 0) return 0;
    return (data.lengthInBytes ~/ bytesPerSample) ~/ channels;
  }

  /// Wall-clock duration this chunk represents.
  Duration get duration {
    if (sampleRate <= 0) return Duration.zero;
    return Duration(microseconds: (frameCount * 1000000) ~/ sampleRate);
  }

  /// The 16-bit samples (interleaved across channels).
  ///
  /// A real recorder chunk is often a [Uint8List] *view* whose `offsetInBytes` is odd, which
  /// `asInt16List` rejects (it requires 2-byte alignment). Aligned views are returned as a zero-copy
  /// view; a misaligned view is copied once into a fresh, aligned buffer. Either way a trailing odd
  /// byte (if any) is ignored.
  Int16List get samples {
    final byteCount = data.lengthInBytes & ~1; // whole 16-bit samples only
    if (byteCount == 0) return Int16List(0);
    if (data.offsetInBytes.isEven) {
      return data.buffer.asInt16List(data.offsetInBytes, byteCount ~/ 2);
    }
    final aligned = data.sublist(0, byteCount); // fresh buffer, offset 0
    return aligned.buffer.asInt16List(0, byteCount ~/ 2);
  }

  /// A copy of this frame stamped with its meeting-timeline [offset]. Shares [data] (no PCM copy).
  AudioFrame withOffset(Duration offset) => AudioFrame(
    source: source,
    capturedAt: capturedAt,
    sampleRate: sampleRate,
    channels: channels,
    data: data,
    format: format,
    offset: offset,
  );
}
