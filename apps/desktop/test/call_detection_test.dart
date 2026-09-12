// Tests for call detection: the prompt controller and the mock detector's once-per-process
// behaviour, plus elapsed-time accounting on the listening session.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/calls/call_detection_state.dart';
import 'package:notely_desktop/features/listening/listening_state.dart';
import 'package:notely_desktop/services/audio/meeting_audio_service.dart';
import 'package:notely_desktop/services/calls/call_detection_service.dart';
import 'package:notely_desktop/services/meeting/summary_service.dart';
import 'package:notely_desktop/services/transcript/transcript_service.dart';

/// A detector we can drive by hand.
class _ManualDetector implements CallDetectionService {
  final _controller = StreamController<DetectedCall>.broadcast();
  int starts = 0;
  int stops = 0;

  @override
  Stream<DetectedCall> get events => _controller.stream;
  @override
  void start() => starts++;
  @override
  void stop() => stops++;
  void fire(DetectedCall call) => _controller.add(call);
  @override
  Future<void> dispose() async => _controller.close();
}

/// Minimal audio fake so the listening controller never touches hardware.
class _SilentAudio implements MeetingAudioService {
  @override
  AudioCapabilities get capabilities => const AudioCapabilities(
    microphone: AudioSourceStatus.available,
    systemAudio: AudioSourceStatus.unsupported,
  );
  @override
  Future<AudioCapabilities> requestPermissions() async => capabilities;
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
  Future<void> dispose() async {}
}

void main() {
  test('a detected call becomes pending and dismiss clears it', () async {
    final detector = _ManualDetector();
    final c = CallDetectionController(service: detector);
    c.start();
    expect(c.hasPending, isFalse);
    expect(detector.starts, 1);

    detector.fire(const DetectedCall(source: 'Zoom', title: 'Standup'));
    await Future<void>.delayed(Duration.zero); // let the stream deliver
    expect(c.hasPending, isTrue);
    expect(c.pending!.source, 'Zoom');

    c.dismiss();
    expect(c.hasPending, isFalse);

    c.dispose();
  });

  test('stop() stops the detector and clears any pending prompt', () async {
    final detector = _ManualDetector();
    final c = CallDetectionController(service: detector);
    c.start();
    detector.fire(const DetectedCall(source: 'Meet'));
    await Future<void>.delayed(Duration.zero);
    expect(c.hasPending, isTrue);

    c.stop();
    expect(detector.stops, 1);
    expect(c.hasPending, isFalse);
    c.dispose();
  });

  test('mock detector simulates at most once, even across restarts', () async {
    final mock = MockCallDetectionService(
      delay: const Duration(milliseconds: 10),
    );
    final seen = <DetectedCall>[];
    final sub = mock.events.listen(seen.add);

    mock.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(seen.length, 1);

    // A second start (e.g. switching stashes) must not re-fire.
    mock.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(seen.length, 1);

    await sub.cancel();
    await mock.dispose();
  });

  test('listening elapsed accumulates and resets across the session', () async {
    final c = ListeningController(
      audio: _SilentAudio(),
      transcript: MockTranscriptService(interval: const Duration(seconds: 999)),
      summary: const MockSummaryService(),
    );
    expect(c.elapsed, Duration.zero);

    await c.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.elapsed.inMilliseconds, greaterThan(0));

    // Pausing freezes the readout.
    await c.pause();
    final atPause = c.elapsed;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.elapsed, atPause);

    await c.stop();
    c.close();
    expect(c.elapsed, Duration.zero); // reset once the session ends
    c.dispose();
  });
}
