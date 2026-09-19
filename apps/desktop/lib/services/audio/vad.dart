// Voice-activity detection (VAD).
//
// VAD produces speech-activity INFORMATION for a frame; it never destroys audio. The segmenter (see
// speech_segmenter.dart) decides what to do with that information. The interface is deliberately
// tiny and replaceable: [EnergyVad] is a simple RMS-threshold detector suitable as a first
// implementation; a real ML VAD can implement the same [VoiceActivityDetector] later without
// touching ingestion or segmentation.

import 'dart:math' as math;

import 'audio_frame.dart';

/// The per-frame verdict: whether the frame contains speech, plus the normalized RMS energy
/// (0..1) that produced it (exposed so a segmenter can log/threshold without re-scanning PCM).
class VadResult {
  const VadResult({required this.isSpeech, required this.energy});
  final bool isSpeech;
  final double energy;
}

/// Replaceable VAD contract. Pure and synchronous — one frame in, one verdict out.
abstract class VoiceActivityDetector {
  VadResult analyze(AudioFrame frame);
}

/// Simple energy-based VAD: a frame is "speech" when its normalized RMS crosses [threshold].
/// Deterministic and dependency-free. Not perfect (music/noise can trip it), but a correct,
/// swappable starting point — the whole point of the [VoiceActivityDetector] seam.
class EnergyVad implements VoiceActivityDetector {
  EnergyVad({this.threshold = 0.02});

  /// Normalized RMS (0..1) at/above which a frame counts as speech. ~0.02 ≈ quiet speech.
  final double threshold;

  @override
  VadResult analyze(AudioFrame frame) {
    final samples = frame.samples;
    if (samples.isEmpty) return const VadResult(isSpeech: false, energy: 0);
    var sumSquares = 0.0;
    for (final s in samples) {
      final n = s / 32768.0;
      sumSquares += n * n;
    }
    final rms = math.sqrt(sumSquares / samples.length);
    return VadResult(isSpeech: rms >= threshold, energy: rms);
  }
}
