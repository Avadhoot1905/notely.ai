// Transcript event interface.
//
// The UI consumes a stream of [TranscriptEvent]s and stays agnostic about the source: today a
// [MockTranscriptService] replays a scripted conversation; later a Rust/Qwen3-ASR-backed
// service will emit the same events from real audio. A segment carries timestamp + speaker +
// text (see [TranscriptEntry]).

import 'dart:async';

import '../../mock/mock_transcript.dart';

export '../../mock/mock_transcript.dart' show TranscriptEntry;

/// Lifecycle + content events for a live transcript.
sealed class TranscriptEvent {
  const TranscriptEvent();
}

class TranscriptStarted extends TranscriptEvent {
  const TranscriptStarted();
}

class TranscriptPausedEvent extends TranscriptEvent {
  const TranscriptPausedEvent();
}

class TranscriptResumedEvent extends TranscriptEvent {
  const TranscriptResumedEvent();
}

class TranscriptSegmentEvent extends TranscriptEvent {
  const TranscriptSegmentEvent(this.segment);
  final TranscriptEntry segment;
}

class TranscriptStoppedEvent extends TranscriptEvent {
  const TranscriptStoppedEvent();
}

abstract class TranscriptService {
  Stream<TranscriptEvent> get events;
  void start();
  void pause();
  void resume();
  void stop();
  Future<void> dispose();
}

/// Replays [mockTranscriptScript] one segment at a time. Honors pause/resume (the timer keeps
/// running but suppresses emissions while paused) and is the default until ASR is wired.
class MockTranscriptService implements TranscriptService {
  MockTranscriptService({this.interval = const Duration(seconds: 3)});

  final Duration interval;
  final StreamController<TranscriptEvent> _controller =
      StreamController<TranscriptEvent>.broadcast();

  Timer? _timer;
  int _index = 0;
  bool _paused = false;

  @override
  Stream<TranscriptEvent> get events => _controller.stream;

  @override
  void start() {
    _stopTimer();
    _index = 0;
    _paused = false;
    _controller.add(const TranscriptStarted());
    _emitNext(); // emit first segment promptly
    _timer = Timer.periodic(interval, (_) => _emitNext());
  }

  void _emitNext() {
    if (_paused) return;
    if (_index >= mockTranscriptScript.length) {
      _stopTimer();
      return;
    }
    _controller.add(TranscriptSegmentEvent(mockTranscriptScript[_index++]));
  }

  @override
  void pause() {
    if (_paused) return;
    _paused = true;
    _controller.add(const TranscriptPausedEvent());
  }

  @override
  void resume() {
    if (!_paused) return;
    _paused = false;
    _controller.add(const TranscriptResumedEvent());
  }

  @override
  void stop() {
    _stopTimer();
    _controller.add(const TranscriptStoppedEvent());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Future<void> dispose() async {
    _stopTimer();
    await _controller.close();
  }
}

/// Emits lifecycle events but NO transcript segments — the honest default for the running app until
/// real ASR is wired. The live transcript stays empty (the UI shows its "waiting for speech" state)
/// instead of replaying canned/dummy lines. [MockTranscriptService] remains for tests/fixtures.
class SilentTranscriptService implements TranscriptService {
  final StreamController<TranscriptEvent> _controller =
      StreamController<TranscriptEvent>.broadcast();

  @override
  Stream<TranscriptEvent> get events => _controller.stream;

  void _emit(TranscriptEvent e) {
    if (!_controller.isClosed) _controller.add(e);
  }

  @override
  void start() => _emit(const TranscriptStarted());
  @override
  void pause() => _emit(const TranscriptPausedEvent());
  @override
  void resume() => _emit(const TranscriptResumedEvent());
  @override
  void stop() => _emit(const TranscriptStoppedEvent());

  @override
  Future<void> dispose() async => _controller.close();
}
