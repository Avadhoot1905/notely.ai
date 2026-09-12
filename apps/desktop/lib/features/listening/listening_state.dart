// Listening / live-transcript state.
//
// This is the seam where the Rust engine plugs in. Today a [MockListeningService] replays a
// scripted transcript on a timer; tomorrow a real service will subscribe to engine events
// (see lib/ipc/engine_client.dart) and push TranscriptEntry items instead. The controller's
// public surface (start/stop + entries stream) stays the same either way.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../mock/mock_transcript.dart';

/// Produces transcript entries while a session is active. Abstracted so the mock can be
/// swapped for an IPC-backed implementation without touching the UI.
abstract class ListeningService {
  /// Begin a session. [onEntry] is called as new transcript lines arrive.
  void start(void Function(TranscriptEntry) onEntry);

  /// End the session and release any resources (timers / subscriptions).
  void stop();
}

/// Replays [mockTranscriptScript] one entry at a time to simulate a live meeting.
/// Set [interval] small in tests, or replace this class entirely with the real service.
class MockListeningService implements ListeningService {
  MockListeningService({this.interval = const Duration(seconds: 3)});

  final Duration interval;
  Timer? _timer;

  @override
  void start(void Function(TranscriptEntry) onEntry) {
    stop();
    var i = 0;
    // Emit the first line promptly so the panel isn't empty on open.
    if (mockTranscriptScript.isNotEmpty) onEntry(mockTranscriptScript[i++]);
    _timer = Timer.periodic(interval, (_) {
      if (i >= mockTranscriptScript.length) {
        _timer?.cancel();
        return;
      }
      onEntry(mockTranscriptScript[i++]);
    });
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

class ListeningController extends ChangeNotifier {
  ListeningController({ListeningService? service})
    : _service = service ?? MockListeningService();

  final ListeningService _service;

  /// The core mock flag from the spec: false → two-column layout, true → transcript panel.
  bool _startListening = false;
  bool get startListening => _startListening;

  final List<TranscriptEntry> _entries = [];
  List<TranscriptEntry> get entries => List.unmodifiable(_entries);

  void toggle() => _startListening ? stop() : start();

  void start() {
    if (_startListening) return;
    _startListening = true;
    _entries.clear();
    _service.start((entry) {
      _entries.add(entry);
      notifyListeners();
    });
    notifyListeners();
  }

  void stop() {
    if (!_startListening) return;
    _startListening = false;
    _service.stop();
    notifyListeners();
  }

  @override
  void dispose() {
    _service.stop();
    super.dispose();
  }
}
