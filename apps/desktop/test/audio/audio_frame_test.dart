import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/services/audio/audio_frame.dart';

/// Build a PCM16 frame of [samples] mono samples all set to [value].
AudioFrame frame(AudioSource source, {int samples = 16, int value = 1000}) {
  final pcm = Int16List(samples);
  for (var i = 0; i < samples; i++) {
    pcm[i] = value;
  }
  return AudioFrame(
    source: source,
    capturedAt: DateTime(2020, 1, 1, 10, 0, 0),
    sampleRate: 16000,
    channels: 1,
    data: pcm.buffer.asUint8List(),
  );
}

void main() {
  test('preserves source, timestamp, and PCM metadata', () {
    final f = frame(AudioSource.system, samples: 1600);
    expect(f.source, AudioSource.system);
    expect(f.capturedAt, DateTime(2020, 1, 1, 10, 0, 0));
    expect(f.sampleRate, 16000);
    expect(f.channels, 1);
    expect(f.format, AudioFormat.pcm16);
    expect(f.bytesPerSample, 2);
    expect(f.frameCount, 1600); // 1600 mono samples
    expect(f.duration, const Duration(milliseconds: 100)); // 1600 / 16000
    expect(f.samples.length, 1600);
    expect(f.samples.first, 1000);
  });

  test('frameCount accounts for channel interleaving', () {
    final pcm = Int16List(3200); // 1600 stereo frames
    final f = AudioFrame(
      source: AudioSource.microphone,
      capturedAt: DateTime(2020),
      sampleRate: 16000,
      channels: 2,
      data: pcm.buffer.asUint8List(),
    );
    expect(f.frameCount, 1600);
    expect(f.duration, const Duration(milliseconds: 100));
  });

  test(
    'withOffset stamps the timeline and SHARES the PCM buffer (no copy)',
    () {
      final f = frame(AudioSource.microphone);
      final stamped = f.withOffset(const Duration(seconds: 3));
      expect(stamped.offset, const Duration(seconds: 3));
      expect(stamped.source, f.source);
      expect(stamped.capturedAt, f.capturedAt);
      // Same underlying bytes — withOffset must not copy PCM.
      expect(identical(stamped.data, f.data), isTrue);
    },
  );

  test('samples handle a misaligned (odd byteOffset) view without throwing', () {
    // Real recorder chunks are views into a larger buffer with an arbitrary (often odd) offset,
    // which asInt16List rejects. Reproduce that: a view starting at byte 5.
    final backing = Uint8List(21);
    final view = Uint8List.sublistView(
      backing,
      5,
    ); // offsetInBytes == 5 (odd), 16 bytes
    expect(view.offsetInBytes.isOdd, isTrue);
    final f = AudioFrame(
      source: AudioSource.system,
      capturedAt: DateTime(2020),
      sampleRate: 16000,
      channels: 1,
      data: view,
    );
    expect(
      () => f.samples,
      returnsNormally,
    ); // was a RangeError in live capture
    expect(f.samples.length, 8); // 16 bytes / 2
  });
}
