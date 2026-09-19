import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/services/audio/audio_frame.dart';
import 'package:notely_desktop/services/audio/wav_recorder.dart';
import 'package:path/path.dart' as p;

Uint8List _pcm(int samples, int value) {
  final s = Int16List(samples);
  for (var i = 0; i < samples; i++) {
    s[i] = value;
  }
  return s.buffer.asUint8List();
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('notely_wav_');
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test(
    'writes a valid PCM16 WAV header with correct sizes and format',
    () async {
      final path = p.join(dir.path, 'out.wav');
      final rec = await WavRecorder.create(
        path: path,
        sampleRate: 44100,
        channels: 2,
      );
      rec.add(_pcm(100, 1000)); // 200 bytes
      rec.add(_pcm(50, -1000)); // 100 bytes
      final out = await rec.finish();
      expect(out, path);

      final bytes = await File(path).readAsBytes();
      final bd = ByteData.view(bytes.buffer);
      const dataBytes = 300;

      String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
      expect(tag(0), 'RIFF');
      expect(bd.getUint32(4, Endian.little), 36 + dataBytes); // RIFF size
      expect(tag(8), 'WAVE');
      expect(tag(12), 'fmt ');
      expect(bd.getUint16(20, Endian.little), 1); // PCM
      expect(bd.getUint16(22, Endian.little), 2); // channels
      expect(bd.getUint32(24, Endian.little), 44100); // sample rate
      expect(bd.getUint32(28, Endian.little), 44100 * 2 * 2); // byte rate
      expect(bd.getUint16(32, Endian.little), 4); // block align
      expect(bd.getUint16(34, Endian.little), 16); // bits/sample
      expect(tag(36), 'data');
      expect(bd.getUint32(40, Endian.little), dataBytes);
      expect(bytes.length, 44 + dataBytes); // header + payload
    },
  );

  test('add after finish is a no-op; dataBytes tracks payload', () async {
    final rec = await WavRecorder.create(
      path: p.join(dir.path, 'a.wav'),
      sampleRate: 16000,
      channels: 1,
    );
    rec.add(_pcm(10, 5)); // 20 bytes
    expect(rec.dataBytes, 20);
    await rec.finish();
    rec.add(_pcm(10, 5)); // ignored
    expect(rec.dataBytes, 20);
  });

  test('createTemp places a uniquely-named file under a temp dir', () async {
    final rec = await WavRecorder.createTemp(
      source: AudioSource.microphone,
      sampleRate: 44100,
      channels: 2,
      nonce: 12345,
    );
    expect(rec.path, contains('notely_captures'));
    expect(rec.path, endsWith('session-12345-microphone.wav'));
    await rec.discard();
    expect(await File(rec.path).exists(), isFalse);
  });
}
