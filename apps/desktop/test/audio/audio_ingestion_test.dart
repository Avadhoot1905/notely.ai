import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/services/audio/audio_frame.dart';
import 'package:notely_desktop/services/audio/audio_ingestion.dart';

AudioFrame frame(AudioSource source, DateTime at) => AudioFrame(
  source: source,
  capturedAt: at,
  sampleRate: 16000,
  channels: 1,
  data: Int16List(160).buffer.asUint8List(), // 10ms
);

void main() {
  final t0 = DateTime(2020, 1, 1, 12, 0, 0);

  test('keeps mic/system frames distinguishable and ordered', () async {
    final ing = AudioIngestion(startedAt: t0);
    final got = <AudioSource>[];
    ing.frames.listen((f) => got.add(f.source));

    ing.add(frame(AudioSource.microphone, t0));
    ing.add(
      frame(AudioSource.system, t0.add(const Duration(milliseconds: 10))),
    );
    ing.add(
      frame(AudioSource.microphone, t0.add(const Duration(milliseconds: 20))),
    );

    await Future<void>.delayed(Duration.zero);
    expect(got, [
      AudioSource.microphone,
      AudioSource.system,
      AudioSource.microphone,
    ]);
    await ing.dispose();
  });

  test('stamps meeting-timeline offsets from the start instant', () async {
    final ing = AudioIngestion(startedAt: t0);
    final offsets = <Duration>[];
    ing.frames.listen((f) => offsets.add(f.offset!));

    ing.add(frame(AudioSource.microphone, t0));
    ing.add(
      frame(AudioSource.system, t0.add(const Duration(milliseconds: 500))),
    );
    await Future<void>.delayed(Duration.zero);

    expect(offsets, [Duration.zero, const Duration(milliseconds: 500)]);
    await ing.dispose();
  });

  test('add() is non-blocking: delivery happens asynchronously', () async {
    final ing = AudioIngestion(startedAt: t0);
    final got = <AudioFrame>[];
    ing.frames.listen(got.add);

    ing.add(frame(AudioSource.microphone, t0));
    // Nothing delivered synchronously — the recorder callback is never blocked.
    expect(got, isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(got, hasLength(1));
    await ing.dispose();
  });

  test('bounded buffer drops OLDEST and counts drops (defined policy)', () async {
    final ing = AudioIngestion(capacity: 2, startedAt: t0);
    final got = <int>[];
    // Tag frames by offset ms so we can see WHICH were kept.
    ing.frames.listen((f) => got.add(f.offset!.inMilliseconds));

    // Five frames enqueued synchronously (before the microtask drain runs) → over capacity 2.
    for (var i = 0; i < 5; i++) {
      ing.add(
        frame(AudioSource.microphone, t0.add(Duration(milliseconds: i * 10))),
      );
    }
    expect(ing.dropped, 3, reason: 'capacity 2, 5 added → 3 oldest dropped');

    await Future<void>.delayed(Duration.zero);
    // Only the freshest two survive (offsets 30ms and 40ms).
    expect(got, [30, 40]);
    await ing.dispose();
  });
}
