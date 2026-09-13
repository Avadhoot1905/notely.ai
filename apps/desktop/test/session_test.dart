// Unit tests for the listening session state machine and summarisation.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/editor/editor_state.dart';
import 'package:notely_desktop/features/listening/listening_state.dart';
import 'package:notely_desktop/services/audio/meeting_audio_service.dart';
import 'package:notely_desktop/services/meeting/summary_service.dart';
import 'package:notely_desktop/services/transcript/transcript_service.dart';
import 'package:path/path.dart' as p;

/// Records lifecycle calls without touching real hardware.
class FakeAudioService implements MeetingAudioService {
  final List<String> calls = [];
  @override
  AudioCapabilities get capabilities => const AudioCapabilities(
    microphone: AudioSourceStatus.available,
    systemAudio: AudioSourceStatus.unsupported,
  );
  @override
  Future<AudioCapabilities> requestPermissions() async => capabilities;
  @override
  Future<void> startMicrophone() async => calls.add('startMic');
  @override
  Future<void> startSystemAudio() async => calls.add('startSys');
  @override
  Future<void> start() async => calls.add('start');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> dispose() async => calls.add('dispose');
}

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('notely_session_');
  });
  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  ListeningController makeController(FakeAudioService audio) =>
      ListeningController(
        audio: audio,
        transcript: MockTranscriptService(
          interval: const Duration(milliseconds: 20),
        ),
        summary: const MockSummaryService(),
      );

  test(
    'state machine: idle → listening → paused → listening → reviewing',
    () async {
      final audio = FakeAudioService();
      final c = makeController(audio);

      expect(c.state, ListeningState.idle);
      await c.start();
      expect(c.state, ListeningState.listening);
      expect(audio.calls, contains('start'));

      await c.pause();
      expect(c.state, ListeningState.paused);
      expect(audio.calls, contains('pause'));

      await c.resume();
      expect(c.state, ListeningState.listening);
      expect(audio.calls, contains('resume'));

      await c.stop();
      expect(c.state, ListeningState.reviewing);
      expect(audio.calls, contains('stop'));

      c.dispose();
    },
  );

  test('transcript segments accumulate while listening', () async {
    final c = makeController(FakeAudioService());
    await c.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(c.entries, isNotEmpty);
    await c.stop();
    // Segments are retained in the review state.
    expect(c.entries, isNotEmpty);
    c.dispose();
  });

  test('summarise writes generated markdown into the open note', () async {
    final path = p.join(tempRoot.path, 'Team Sync.md');
    await File(path).writeAsString('# Team Sync\n');
    final editor = EditorController();
    await editor.open(path);

    final c = makeController(FakeAudioService());
    await c.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await c.stop();

    final ok = await c.summarise(editor: editor);
    expect(ok, isTrue);
    expect(c.state, ListeningState.idle); // review closed after summarise
    final onDisk = await File(path).readAsString();
    expect(onDisk, contains('## Meeting Summary'));
    expect(onDisk, contains('# Team Sync')); // original content preserved

    editor.dispose();
    c.dispose();
  });

  test(
    'deferred enrichment is a safe outcome: notice, no error, session ends, file untouched',
    () async {
      final path = p.join(tempRoot.path, 'Deferred.md');
      await File(path).writeAsString('# Deferred\n');
      final editor = EditorController();
      await editor.open(path);

      final c = ListeningController(
        audio: FakeAudioService(),
        transcript: MockTranscriptService(
          interval: const Duration(milliseconds: 20),
        ),
        summary: _DeferringSummary(),
      );
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await c.stop();

      final ok = await c.summarise(editor: editor);
      // Treated as handled/safe — the source is persisted by the engine, only AI is deferred.
      expect(ok, isTrue);
      expect(c.state, ListeningState.idle);
      expect(c.summariseError, isNull, reason: 'deferral is not an error');
      expect(
        c.notice,
        isNotNull,
        reason: 'user is reassured the capture is saved',
      );
      // The note file was NOT overwritten with a fake summary.
      final onDisk = await File(path).readAsString();
      expect(onDisk, '# Deferred\n');

      editor.dispose();
      c.dispose();
    },
  );

  test('a genuine failure stays in review so the user can retry', () async {
    final path = p.join(tempRoot.path, 'Broken.md');
    await File(path).writeAsString('# Broken\n');
    final editor = EditorController();
    await editor.open(path);

    final c = ListeningController(
      audio: FakeAudioService(),
      transcript: MockTranscriptService(
        interval: const Duration(milliseconds: 20),
      ),
      summary: _FailingSummary(),
    );
    await c.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await c.stop();

    final ok = await c.summarise(editor: editor);
    expect(ok, isFalse);
    expect(
      c.state,
      ListeningState.reviewing,
      reason: 'stay in review to retry',
    );
    expect(c.summariseError, isNotNull);
    expect(c.entries, isNotEmpty, reason: 'transcript retained for retry');

    editor.dispose();
    c.dispose();
  });

  test('close discards review without touching the file', () async {
    final c = makeController(FakeAudioService());
    await c.start();
    await c.stop();
    c.close();
    expect(c.state, ListeningState.idle);
    expect(c.entries, isEmpty);
    c.dispose();
  });

  test('pause does not end the session', () async {
    final c = makeController(FakeAudioService());
    await c.start();
    await c.pause();
    expect(c.showTranscript, isTrue);
    expect(c.state, ListeningState.paused);
    c.dispose();
  });
}

/// Simulates the engine persisting the source but deferring AI enrichment (e.g. LLM offline).
class _DeferringSummary implements SummaryService {
  @override
  Future<String> summarise({
    required List<TranscriptEntry> segments,
    required String currentMarkdown,
    String? title,
  }) async {
    throw const DeferredProcessingException(
      meetingId: 'meeting-1',
      reason: 'model unavailable',
    );
  }
}

/// Simulates a genuine, non-deferred failure (nothing safely persisted downstream).
class _FailingSummary implements SummaryService {
  @override
  Future<String> summarise({
    required List<TranscriptEntry> segments,
    required String currentMarkdown,
    String? title,
  }) async {
    throw Exception('backend exploded');
  }
}
