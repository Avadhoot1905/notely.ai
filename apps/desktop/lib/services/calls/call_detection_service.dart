// Call/meeting detection abstraction.
//
// Watches for a call being placed or joined so the app can offer to take notes (like Granola
// noticing you've entered a Zoom/Meet/Teams call). The UI only ever talks to this interface.
//
// Real detection is inherently OS-level — enumerating running conferencing apps, observing the
// active audio device, or reading the calendar — and belongs in native code / the Rust engine.
// Until that exists, [MockCallDetectionService] simulates a single detection so the whole
// notes-prompt → listening flow is exercisable without pretending we truly detect calls.

import 'dart:async';

import 'package:flutter/foundation.dart';

/// A call that was placed or joined, surfaced so we can offer to take notes for it.
@immutable
class DetectedCall {
  const DetectedCall({required this.source, this.title});

  /// The conferencing app the call was detected in (e.g. "Google Meet", "Zoom", "Teams").
  final String source;

  /// Best-effort meeting title, when the source exposes one.
  final String? title;
}

abstract class CallDetectionService {
  Stream<DetectedCall> get events;

  /// Begin watching for calls. Safe to call more than once.
  void start();

  /// Stop watching (e.g. when no stash is open).
  void stop();

  Future<void> dispose();
}

/// Simulates detecting a call exactly once per process, a short while after [start]. This keeps
/// the prompt demonstrable without being repeatedly intrusive; a real detector would emit only
/// on genuine calls. [simulate] forces a detection immediately (handy for tests / a menu action).
class MockCallDetectionService implements CallDetectionService {
  MockCallDetectionService({this.delay = const Duration(seconds: 8)});

  final Duration delay;
  final StreamController<DetectedCall> _controller =
      StreamController<DetectedCall>.broadcast();

  Timer? _timer;
  bool _hasSimulated = false;

  @override
  Stream<DetectedCall> get events => _controller.stream;

  @override
  void start() {
    if (_hasSimulated || _timer != null) return;
    _timer = Timer(delay, () {
      _timer = null;
      _hasSimulated = true;
      simulate(
        call: const DetectedCall(source: 'Google Meet', title: 'Team Sync'),
      );
    });
  }

  /// Emit a detection now.
  void simulate({DetectedCall call = const DetectedCall(source: 'Zoom')}) {
    if (!_controller.isClosed) _controller.add(call);
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _controller.close();
  }
}
