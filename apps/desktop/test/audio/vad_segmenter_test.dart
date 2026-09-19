import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/services/audio/audio_frame.dart';
import 'package:notely_desktop/services/audio/speech_segmenter.dart';
import 'package:notely_desktop/services/audio/vad.dart';

/// A 100ms PCM16 frame at `amp` (0..1) normalized loudness, stamped at `offsetMs`.
/// Alternating ±(amp*full-scale) gives RMS ≈ amp, so [EnergyVad] sees exactly `amp`.
AudioFrame f({
  required double amp,
  required int offsetMs,
  int ms = 100,
  AudioSource source = AudioSource.microphone,
}) {
  final n = 16000 * ms ~/ 1000;
  final v = (amp * 32767).round();
  final data = Int16List(n);
  for (var i = 0; i < n; i++) {
    data[i] = i.isEven ? v : -v;
  }
  return AudioFrame(
    source: source,
    capturedAt: DateTime(2020),
    sampleRate: 16000,
    channels: 1,
    data: data.buffer.asUint8List(),
    offset: Duration(milliseconds: offsetMs),
  );
}

/// Run a sequence through a fresh segmenter and collect all emitted segments (incl. flush).
List<SpeechSegment> run(List<AudioFrame> frames, {SpeechSegmenter? seg}) {
  final s = seg ?? SpeechSegmenter(source: AudioSource.microphone);
  final out = <SpeechSegment>[];
  for (final fr in frames) {
    final done = s.add(fr);
    if (done != null) out.add(done);
  }
  final last = s.flush();
  if (last != null) out.add(last);
  return out;
}

void main() {
  group('EnergyVad', () {
    final vad = EnergyVad();
    test('silence is not speech', () {
      expect(vad.analyze(f(amp: 0, offsetMs: 0)).isSpeech, isFalse);
    });
    test('loud audio is speech', () {
      final r = vad.analyze(f(amp: 0.2, offsetMs: 0));
      expect(r.isSpeech, isTrue);
      expect(r.energy, closeTo(0.2, 0.01));
    });
    test('very quiet audio below threshold is not speech', () {
      expect(vad.analyze(f(amp: 0.005, offsetMs: 0)).isSpeech, isFalse);
    });
  });

  group('SpeechSegmenter', () {
    test('silence produces no segments', () {
      final frames = [
        for (var i = 0; i < 10; i++) f(amp: 0, offsetMs: i * 100),
      ];
      expect(run(frames), isEmpty);
    });

    test('speech produces one segment with correct source and timestamps', () {
      final frames = <AudioFrame>[
        for (var i = 0; i < 3; i++) f(amp: 0, offsetMs: i * 100), // pre-roll
        for (var i = 3; i < 8; i++)
          f(amp: 0.2, offsetMs: i * 100), // 500ms speech
        for (var i = 8; i < 14; i++)
          f(amp: 0, offsetMs: i * 100), // 600ms silence → close
      ];
      final segs = run(frames);
      expect(segs, hasLength(1));
      final s = segs.first;
      expect(s.source, AudioSource.microphone);
      // Pre-roll is included → segment starts before the first speech frame (300ms).
      expect(s.start, Duration.zero);
      expect(
        s.frames.length,
        greaterThan(5),
        reason: 'pre-roll + speech + hangover',
      );
      expect(s.meanEnergy, closeTo(0.2, 0.02));
      expect(s.end, greaterThan(s.start));
    });

    test('a short pause inside speech does NOT split the segment', () {
      final frames = <AudioFrame>[
        for (var i = 0; i < 3; i++) f(amp: 0, offsetMs: i * 100), // pre-roll
        for (var i = 3; i < 6; i++) f(amp: 0.2, offsetMs: i * 100), // speech
        for (var i = 6; i < 8; i++)
          f(amp: 0, offsetMs: i * 100), // 200ms pause (< hangover)
        for (var i = 8; i < 11; i++) f(amp: 0.2, offsetMs: i * 100), // speech
        for (var i = 11; i < 17; i++)
          f(amp: 0, offsetMs: i * 100), // 600ms silence → close
      ];
      final segs = run(frames);
      expect(
        segs,
        hasLength(1),
        reason: 'the 200ms pause is absorbed by hangover',
      );
    });

    test('a sub-minimum blip is discarded', () {
      final frames = <AudioFrame>[
        for (var i = 0; i < 3; i++) f(amp: 0, offsetMs: i * 100), // pre-roll
        f(amp: 0.2, offsetMs: 300), // 100ms speech only (< 250ms minSpeech)
        for (var i = 4; i < 10; i++)
          f(amp: 0, offsetMs: i * 100), // silence → close
      ];
      expect(run(frames), isEmpty);
    });

    test('keeps sources separate via distinct segmenter instances', () {
      final mic = SpeechSegmenter(source: AudioSource.microphone);
      final sys = SpeechSegmenter(source: AudioSource.system);
      final micSegs = run([
        for (var i = 0; i < 5; i++)
          f(amp: 0.2, offsetMs: i * 100, source: AudioSource.microphone),
        for (var i = 5; i < 12; i++)
          f(amp: 0, offsetMs: i * 100, source: AudioSource.microphone),
      ], seg: mic);
      final sysSegs = run([
        for (var i = 0; i < 5; i++)
          f(amp: 0, offsetMs: i * 100, source: AudioSource.system),
      ], seg: sys);
      expect(micSegs.single.source, AudioSource.microphone);
      expect(sysSegs, isEmpty);
    });
  });
}
