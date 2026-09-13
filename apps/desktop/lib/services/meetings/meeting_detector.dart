// Meeting detector abstraction.
//
// A detector watches the OS for the user joining/leaving a supported meeting and emits normalized
// [MeetingDetectedEvent] / [MeetingEndedEvent]. Detection is provider-based and OS-specific, but
// the shared app layer depends only on this interface — never on how a platform figures out that
// a meeting is active (running apps, microphone-in-use, window titles, …).
//
// Implementations:
//   * [PlatformMeetingDetector] — bridges to native code over a platform channel (macOS today;
//     Windows/Linux return no events until their native detectors land).
//   * [MockMeetingDetector] — deterministic, for tests and manual simulation.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'meeting_event.dart';

abstract class MeetingDetector {
  /// Meetings the user appears to have joined/started.
  Stream<MeetingDetectedEvent> get detections;

  /// Meetings that have ended.
  Stream<MeetingEndedEvent> get endings;

  /// Begin watching. [enabledProviders] limits which sources are reported. Idempotent.
  Future<void> start({Set<MeetingProvider> enabledProviders});

  /// Stop watching (keeps the object reusable).
  Future<void> stop();

  Future<void> dispose();
}

/// Bridges to a native detector over method + event channels. On platforms without a native
/// implementation the event channel simply never emits, so the app degrades to "no detections"
/// rather than faking them.
class PlatformMeetingDetector implements MeetingDetector {
  PlatformMeetingDetector({MethodChannel? method, EventChannel? events})
    : _method = method ?? const MethodChannel(_methodChannelName),
      _events = events ?? const EventChannel(_eventChannelName);

  static const _methodChannelName = 'notely/meeting_detector';
  static const _eventChannelName = 'notely/meeting_detector/events';

  final MethodChannel _method;
  final EventChannel _events;

  final _detections = StreamController<MeetingDetectedEvent>.broadcast();
  final _endings = StreamController<MeetingEndedEvent>.broadcast();
  StreamSubscription<dynamic>? _nativeSub;
  bool _started = false;

  @override
  Stream<MeetingDetectedEvent> get detections => _detections.stream;

  @override
  Stream<MeetingEndedEvent> get endings => _endings.stream;

  @override
  Future<void> start({Set<MeetingProvider> enabledProviders = const {}}) async {
    if (_started) {
      await _sendEnabled(enabledProviders);
      return;
    }
    _started = true;
    _nativeSub = _events.receiveBroadcastStream().listen(
      _onNativeEvent,
      onError: (Object e) {
        // A missing native implementation surfaces as an error on the channel — treat as
        // "detection unavailable on this platform" and stay quiet.
        if (kDebugMode) debugPrint('MeetingDetector channel error: $e');
      },
    );
    try {
      await _method.invokeMethod('start', {
        'providers': enabledProviders.map((p) => p.id).toList(),
      });
    } on MissingPluginException {
      // No native detector on this platform yet — fine, we just won't receive events.
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('MeetingDetector start failed: ${e.message}');
    }
  }

  Future<void> _sendEnabled(Set<MeetingProvider> providers) async {
    try {
      await _method.invokeMethod('setProviders', {
        'providers': providers.map((p) => p.id).toList(),
      });
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  void _onNativeEvent(dynamic raw) {
    if (raw is! Map) return;
    switch (raw['type']) {
      case 'detected':
        _detections.add(MeetingDetectedEvent.fromMap(raw));
      case 'ended':
        _endings.add(MeetingEndedEvent.fromMap(raw));
    }
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _nativeSub?.cancel();
    _nativeSub = null;
    try {
      await _method.invokeMethod('stop');
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _detections.close();
    await _endings.close();
  }
}

/// Deterministic detector for tests and manual simulation (e.g. a debug menu action).
class MockMeetingDetector implements MeetingDetector {
  final _detections = StreamController<MeetingDetectedEvent>.broadcast();
  final _endings = StreamController<MeetingEndedEvent>.broadcast();
  Set<MeetingProvider> enabledProviders = const {};
  bool started = false;

  @override
  Stream<MeetingDetectedEvent> get detections => _detections.stream;

  @override
  Stream<MeetingEndedEvent> get endings => _endings.stream;

  @override
  Future<void> start({Set<MeetingProvider> enabledProviders = const {}}) async {
    started = true;
    this.enabledProviders = enabledProviders;
  }

  @override
  Future<void> stop() async => started = false;

  /// Emit a detection now (ignored for disabled providers, mirroring native behaviour).
  void emitDetected(MeetingDetectedEvent event) {
    if (enabledProviders.isNotEmpty &&
        !enabledProviders.contains(event.provider)) {
      return;
    }
    if (!_detections.isClosed) _detections.add(event);
  }

  void emitEnded(MeetingEndedEvent event) {
    if (!_endings.isClosed) _endings.add(event);
  }

  @override
  Future<void> dispose() async {
    started = false;
    await _detections.close();
    await _endings.close();
  }
}
