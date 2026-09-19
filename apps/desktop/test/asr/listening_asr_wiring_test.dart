// Verifies the Phase-1 batch ASR wiring inside ListeningController:
//   mic frames → WAV recording → AsrEngine.transcribe() → TranscriptFinalized → entries.
// The engine/IPC is faked via a stub AsrEngine; capture is driven through a controllable audio fake.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/listening/listening_state.dart';
import 'package:notely_desktop/services/asr/asr_engine.dart';
import 'package:notely_desktop/services/audio/audio_frame.dart';
import 'package:notely_desktop/services/audio/meeting_audio_service.dart';
import 'package:notely_desktop/services/meeting/transcript_segment.dart';

/// Audio fake whose [frames] stream the test drives directly.
class ControllableAudioService implements MeetingAudioService {
  final _frames = StreamController<AudioFrame>.broadcast();
  @override
  AudioCapabilities get capabilities => const AudioCapabilities(
    microphone: AudioSourceStatus.available,
    systemAudio: AudioSourceStatus.unsupported,
  );
  @override
  Future<AudioCapabilities> requestPermissions() async => capabilities;
  @override
  Stream<AudioFrame> get frames => _frames.stream;

  void emitMic({int samples = 512, int value = 1200}) {
    final pcm = Int16List(samples);
    for (var i = 0; i < samples; i++) {
      pcm[i] = value;
    }
    _frames.add(
      AudioFrame(
        source: AudioSource.microphone,
        capturedAt: DateTime(2026, 1, 1, 10),
        sampleRate: 44100,
        channels: 2,
        data: pcm.buffer.asUint8List(),
      ),
    );
  }

  @override
  Future<void> startMicrophone() async {}
  @override
  Future<void> startSystemAudio() async {}
  @override
  Future<void> start() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async => _frames.close();
}

/// AsrEngine stub: records what it was handed and returns scripted transcripts (or throws).
class StubAsrEngine implements AsrEngine {
  StubAsrEngine({this.result, this.error, this.chunkResult});
  final List<TranscriptSegment>? result; // batch pass
  final Object? error; // batch error
  final List<TranscriptSegment>? chunkResult; // live per-segment
  AudioRecording? received;
  final List<AudioChunk> chunks = [];

  @override
  Future<List<TranscriptSegment>> transcribe(AudioRecording recording) async {
    received = recording;
    if (error != null) throw error!;
    return result ?? const [];
  }

  @override
  Future<List<TranscriptSegment>> transcribeChunk(AudioChunk chunk) async {
    chunks.add(chunk);
    return chunkResult ?? const [];
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 80));

void main() {
  test('captured mic audio is transcribed and appears in entries', () async {
    final audio = ControllableAudioService();
    final asr = StubAsrEngine(
      result: [
        const TranscriptSegment(
          id: 'x',
          start: Duration.zero,
          end: Duration(seconds: 1),
          source: AudioSource.microphone,
          text: 'hello world',
        ),
      ],
    );
    final c = ListeningController(audio: audio, asr: asr);

    await c.start();
    audio.emitMic(); // triggers lazy recorder creation (async open)
    await _settle(); // let the WAV file open
    audio.emitMic(); // recorded for sure now
    audio.emitMic();
    await _settle();

    await c.stop();
    await _settle(); // let the (unawaited) transcription finish

    expect(asr.received, isNotNull);
    expect(asr.received!.source, AudioSource.microphone);
    expect(asr.received!.path, endsWith('.wav'));
    expect(c.entries.map((e) => e.text), contains('hello world'));
    expect(c.isTranscribing, isFalse);

    c.dispose();
    audio.dispose();
  });

  test('a closed mic segment is transcribed live and appended', () async {
    final audio = ControllableAudioService();
    final asr = StubAsrEngine(
      chunkResult: [
        const TranscriptSegment(
          id: 'live',
          start: Duration.zero,
          end: Duration(milliseconds: 400),
          source: AudioSource.microphone,
          text: 'live preview',
        ),
      ],
      result: const [], // batch finds nothing extra → live preview stays
    );
    final c = ListeningController(audio: audio, asr: asr);

    await c.start();
    await _settle(); // let the recorder open before frames flow
    // ~350ms of speech then ~700ms of silence → the segmenter closes one segment (minSpeech 250ms,
    // hangover 600ms). Each 512-sample stereo frame at 44.1kHz ≈ 5.8ms.
    for (var i = 0; i < 60; i++) {
      audio.emitMic(value: 1400);
    }
    for (var i = 0; i < 120; i++) {
      audio.emitMic(
        value: 0,
      ); // silence → trips the hangover, closing the segment
    }
    await _settle();
    await _settle();

    expect(
      asr.chunks,
      isNotEmpty,
      reason: 'the closed segment was sent to live ASR',
    );
    expect(asr.chunks.first.source, AudioSource.microphone);
    expect(c.entries.map((e) => e.text), contains('live preview'));

    await c.stop();
    await _settle();
    c.dispose();
    audio.dispose();
  });

  test('ASR unavailable surfaces a notice, not a crash', () async {
    final audio = ControllableAudioService();
    final asr = StubAsrEngine(
      error: const AsrUnavailableException('engine not connected'),
    );
    final c = ListeningController(audio: audio, asr: asr);

    await c.start();
    audio.emitMic();
    await _settle();
    audio.emitMic();
    await _settle();
    await c.stop();
    await _settle();

    expect(c.entries, isEmpty);
    expect(c.notice, isNotNull);
    expect(c.isTranscribing, isFalse);

    c.dispose();
    audio.dispose();
  });

  test(
    'no asr engine → capture runs but no transcription is attempted',
    () async {
      final audio = ControllableAudioService();
      final c = ListeningController(audio: audio); // asr: null

      await c.start();
      audio.emitMic();
      await _settle();
      await c.stop();
      await _settle();

      expect(c.entries, isEmpty);
      expect(c.isTranscribing, isFalse);

      c.dispose();
      audio.dispose();
    },
  );
}
