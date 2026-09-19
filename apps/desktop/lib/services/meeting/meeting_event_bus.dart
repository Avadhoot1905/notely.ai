// Meeting event bus — a broadcast fan-out for [MeetingEvent]s.
//
// Producers call [emit]; any number of independent consumers subscribe to [events]. Deliberately
// trivial (a broadcast StreamController) — the value is the boundary, not the machinery.

import 'dart:async';

import 'meeting_events.dart';

class MeetingEventBus {
  final StreamController<MeetingEvent> _controller =
      StreamController<MeetingEvent>.broadcast();

  /// The event stream. Broadcast: multiple consumers, each independent.
  Stream<MeetingEvent> get events => _controller.stream;

  bool get isClosed => _controller.isClosed;

  void emit(MeetingEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  Future<void> dispose() => _controller.close();
}
