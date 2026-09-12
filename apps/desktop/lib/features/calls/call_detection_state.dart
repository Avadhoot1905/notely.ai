// Call-detection state.
//
// Surfaces the most recent [DetectedCall] awaiting a user decision (via [pending]) so a prompt
// can ask whether to take notes. The prompt clears when the user acts on it, when detection is
// stopped (no stash open), or after a timeout so a missed prompt never lingers. Kept separate
// from [ListeningController]: this owns "should we offer to record?", that owns the session.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/calls/call_detection_service.dart';

class CallDetectionController extends ChangeNotifier {
  CallDetectionController({CallDetectionService? service})
    : _service = service ?? MockCallDetectionService();

  final CallDetectionService _service;
  StreamSubscription<DetectedCall>? _sub;
  Timer? _autoDismiss;

  /// How long an unanswered prompt stays up before it dismisses itself.
  static const _linger = Duration(seconds: 20);

  DetectedCall? _pending;
  DetectedCall? get pending => _pending;
  bool get hasPending => _pending != null;

  /// Begin watching for calls. Idempotent.
  void start() {
    _sub ??= _service.events.listen(_onDetected);
    _service.start();
  }

  /// Stop watching and clear any pending prompt.
  void stop() {
    _service.stop();
    dismiss();
  }

  void _onDetected(DetectedCall call) {
    _pending = call;
    _autoDismiss?.cancel();
    _autoDismiss = Timer(_linger, dismiss);
    notifyListeners();
  }

  /// The user answered (or the prompt timed out); take it down.
  void dismiss() {
    _autoDismiss?.cancel();
    _autoDismiss = null;
    if (_pending == null) return;
    _pending = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _sub?.cancel();
    _service.dispose();
    super.dispose();
  }
}
