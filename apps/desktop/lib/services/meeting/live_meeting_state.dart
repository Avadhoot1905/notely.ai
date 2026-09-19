// Live Meeting State — the projection consumed by the UI.
//
// Consumes [MeetingEvent]s and maintains a single, immutable snapshot the widget/main UI render
// from. The UI must NOT reconstruct transcript state from raw audio/ASR — it reads [state] here.

import 'package:flutter/foundation.dart';

import '../audio/meeting_audio_service.dart' show AudioCapabilities;
import 'meeting_events.dart';
import 'transcript_segment.dart';

enum MeetingStatus { idle, live, paused, ended }

/// Immutable snapshot of the live meeting.
@immutable
class LiveMeetingState {
  const LiveMeetingState({
    this.status = MeetingStatus.idle,
    this.elapsed = Duration.zero,
    this.partial,
    this.transcript = const [],
    this.audioHealth,
  });

  final MeetingStatus status;
  final Duration elapsed;

  /// The in-progress (partial) transcript segment, if the ASR engine emits partials.
  final TranscriptSegment? partial;

  /// Finalized transcript segments in arrival order.
  final List<TranscriptSegment> transcript;

  /// Latest capture health, if reported.
  final AudioCapabilities? audioHealth;

  LiveMeetingState _copy({
    MeetingStatus? status,
    Duration? elapsed,
    TranscriptSegment? partial,
    bool clearPartial = false,
    List<TranscriptSegment>? transcript,
    AudioCapabilities? audioHealth,
  }) => LiveMeetingState(
    status: status ?? this.status,
    elapsed: elapsed ?? this.elapsed,
    partial: clearPartial ? null : (partial ?? this.partial),
    transcript: transcript ?? this.transcript,
    audioHealth: audioHealth ?? this.audioHealth,
  );
}

/// Folds the meeting event stream into a [LiveMeetingState] and notifies listeners on change.
class LiveMeetingStateController extends ChangeNotifier {
  LiveMeetingState _state = const LiveMeetingState();
  LiveMeetingState get state => _state;

  /// Subscribe to a bus. The returned subscription is owned by the caller (cancel on teardown).
  void apply(MeetingEvent event) {
    switch (event) {
      case MeetingStarted():
        // A new meeting resets the projection.
        _state = LiveMeetingState(
          status: MeetingStatus.live,
          elapsed: event.at,
        );
      case MeetingPaused():
        _state = _state._copy(status: MeetingStatus.paused, elapsed: event.at);
      case MeetingResumed():
        _state = _state._copy(status: MeetingStatus.live, elapsed: event.at);
      case MeetingStopped():
        _state = _state._copy(status: MeetingStatus.ended, elapsed: event.at);
      case TranscriptPartial(:final segment):
        _state = _state._copy(elapsed: event.at, partial: segment);
      case TranscriptFinalized(:final segment):
        _state = _state._copy(
          elapsed: event.at,
          transcript: [..._state.transcript, segment],
          clearPartial: true,
        );
      case TranscriptReplaced(:final segments):
        _state = _state._copy(
          elapsed: event.at,
          transcript: List.unmodifiable(segments),
          clearPartial: true,
        );
      case AudioHealthChanged(:final health):
        _state = _state._copy(audioHealth: health);
    }
    notifyListeners();
  }

  /// Reset to idle/empty (e.g. when a review is discarded).
  void reset() {
    _state = const LiveMeetingState();
    notifyListeners();
  }
}
