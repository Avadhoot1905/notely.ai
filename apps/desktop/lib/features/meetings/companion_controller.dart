// CompanionController — the companion's presentation layer.
//
// The companion is a *projection* of the one live meeting, not a second pipeline. This controller:
//   • projects [LiveMeetingState] (transcript + status, incl. partials) into a serializable
//     [CompanionSnapshot] and pushes it to the native overlay window reactively (never polling
//     transcript; a 1s tick only refreshes the elapsed clock);
//   • owns COMPANION-only presentation state ([CompanionState]: visibility / expansion / position),
//     kept entirely separate from meeting state so the companion is disposable/recreatable without
//     touching the meeting.
//
// It NEVER touches audio: no PCM, AudioFrame, MeetingAudioService, VAD, ASR, or storage. It reads the
// projected meeting state and drives the window. The meeting lifecycle (pause/resume/stop) stays in
// MeetingSessionManager / ListeningController — this controller only presents.

// Named required params bind to private fields (`_x = x`); named args can't start with `_`, so
// `prefer_initializing_formals` can't apply here.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../../services/companion/companion_window_service.dart';
import '../../services/meeting/live_meeting_state.dart';
import '../../services/meeting/transcript_segment.dart';

/// Whether the overlay is on screen.
enum CompanionVisibility { hidden, shown }

/// Collapsed pill vs. expanded popover (mirrors the native window's size mode).
enum CompanionExpansion { collapsed, expanded }

/// Immutable companion presentation state — deliberately independent of [LiveMeetingState].
@immutable
class CompanionState {
  const CompanionState({
    this.visibility = CompanionVisibility.hidden,
    this.expansion = CompanionExpansion.collapsed,
    this.position,
  });

  final CompanionVisibility visibility;
  final CompanionExpansion expansion;

  /// User-chosen window position, or null for the default edge placement. Owned here (a future
  /// settings system can persist it) — never stored in meeting state.
  final Offset? position;

  bool get isVisible => visibility == CompanionVisibility.shown;
  bool get isExpanded => expansion == CompanionExpansion.expanded;

  CompanionState copyWith({
    CompanionVisibility? visibility,
    CompanionExpansion? expansion,
    Offset? position,
  }) => CompanionState(
    visibility: visibility ?? this.visibility,
    expansion: expansion ?? this.expansion,
    position: position ?? this.position,
  );
}

/// Max finalized lines pushed to the compact overlay (it shows the tail of the conversation).
const int _maxCompanionLines = 40;

class CompanionController extends ChangeNotifier {
  CompanionController({
    required CompanionWindowService window,
    required Listenable source,
    required LiveMeetingState Function() liveState,
    required Duration Function() elapsed,
    String? Function()? title,
  }) : _window = window,
       _source = source,
       _liveState = liveState,
       _elapsed = elapsed,
       _title = title {
    _source.addListener(_onMeetingChanged);
  }

  final CompanionWindowService _window;
  final Listenable _source;
  final LiveMeetingState Function() _liveState;
  final Duration Function() _elapsed;
  final String? Function()? _title;

  CompanionState _state = const CompanionState();
  CompanionState get state => _state;

  Timer? _clock;

  /// Show the overlay and push the current projection. Idempotent.
  Future<void> show() async {
    _state = _state.copyWith(visibility: CompanionVisibility.shown);
    notifyListeners();
    await _window.show();
    await _push();
    _clock ??= Timer.periodic(const Duration(seconds: 1), (_) => _push());
  }

  /// Hide the overlay. Idempotent; leaves meeting state untouched.
  Future<void> hide() async {
    _clock?.cancel();
    _clock = null;
    _state = _state.copyWith(visibility: CompanionVisibility.hidden);
    notifyListeners();
    await _window.hide();
  }

  /// Reflect the native window's expand/collapse (presentation only — never meeting state).
  void setExpanded(bool expanded) {
    final next = expanded
        ? CompanionExpansion.expanded
        : CompanionExpansion.collapsed;
    if (_state.expansion == next) return;
    _state = _state.copyWith(expansion: next);
    notifyListeners();
  }

  /// Record a user-chosen position (presentation only — never meeting state).
  void setPosition(Offset position) {
    _state = _state.copyWith(position: position);
    notifyListeners();
  }

  void _onMeetingChanged() {
    // Reactive: transcript/status changes propagate here (no polling). Only work while visible.
    if (_state.isVisible) unawaited(_push());
  }

  Future<void> _push() async {
    if (!_state.isVisible) return;
    await _window.update(
      project(_liveState(), title: _title?.call(), elapsed: _elapsed()),
    );
  }

  /// Pure projection: [LiveMeetingState] → [CompanionSnapshot]. Static + side-effect-free so the
  /// mapping (status, transcript tail, partial, timestamps) is directly unit-testable.
  static CompanionSnapshot project(
    LiveMeetingState live, {
    String? title,
    required Duration elapsed,
  }) {
    final tail = live.transcript.length > _maxCompanionLines
        ? live.transcript.sublist(live.transcript.length - _maxCompanionLines)
        : live.transcript;
    return CompanionSnapshot(
      status: _statusString(live.status),
      paused: live.status == MeetingStatus.paused,
      elapsedSeconds: elapsed.inSeconds,
      lines: [for (final s in tail) _line(s)],
      partial: live.partial == null ? null : _line(live.partial!),
      meetingTitle: title,
    );
  }

  static Map<String, String> _line(TranscriptSegment s) => {
    'speaker': s.speaker ?? '',
    'time': _fmt(s.start),
    'text': s.text,
  };

  static String _statusString(MeetingStatus s) => switch (s) {
    MeetingStatus.idle => 'idle',
    MeetingStatus.live => 'listening',
    MeetingStatus.paused => 'paused',
    MeetingStatus.ended => 'stopped',
  };

  /// Meeting-relative `mm:ss` (or `h:mm:ss`) — the existing timestamp model, no parallel index.
  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void dispose() {
    _clock?.cancel();
    _source.removeListener(_onMeetingChanged);
    super.dispose();
  }
}
