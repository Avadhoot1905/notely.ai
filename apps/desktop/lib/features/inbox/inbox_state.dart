// Inbox: captured material that has been safely persisted, shown with its processing state.
//
// This is the "capture first, organize later" surface. It is deliberately a thin VIEW over the
// engine's existing meetings + their durable ProcessingStatus (via ListMeetings) — no second
// store, no new index. Deferred/failed captures can be retried in place (ReprocessMeeting), which
// the engine performs idempotently (never duplicating a capture). When enrichment finishes, the
// result flows into the same vault/search/Ask path as everything else.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../ipc/engine_client.dart';
import '../../ipc/protocol.dart';

class InboxController extends ChangeNotifier {
  InboxController({required this.engine});

  final EngineClient engine;

  bool _open = false;
  bool _loading = false;
  List<MeetingSummary> _items = const [];
  String? _error;

  StreamSubscription<EngineEvent>? _eventsSub;
  VoidCallback? _stateListener;

  bool get isOpen => _open;
  bool get isLoading => _loading;
  String? get error => _error;

  /// All captured meetings, newest first (the engine already orders them).
  List<MeetingSummary> get items => List.unmodifiable(_items);

  /// Count of captures still awaiting attention (anything not `ready`). Drives a subtle badge.
  int get pendingCount => _items
      .where(
        (m) =>
            (m.status?.state ?? ProcessingState.ready) != ProcessingState.ready,
      )
      .length;

  /// Begin keeping the inbox fresh: reload when the engine (re)connects and whenever a processing
  /// job finishes, so retried/enriched captures update without manual refresh.
  void start() {
    _stateListener = () {
      if (engine.isConnected) unawaited(refresh());
    };
    engine.state.addListener(_stateListener!);
    _eventsSub = engine.events().listen((e) {
      if (e.type == EngineEventType.jobCompleted ||
          e.type == EngineEventType.jobFailed) {
        unawaited(refresh());
      }
    });
    if (engine.isConnected) unawaited(refresh());
  }

  void open() {
    if (_open) return;
    _open = true;
    notifyListeners();
    unawaited(refresh());
  }

  void close() {
    if (!_open) return;
    _open = false;
    notifyListeners();
  }

  void toggle() => _open ? close() : open();

  /// Reload the captured-meeting list from the engine. Degrades to an empty list (not an error)
  /// when the engine is offline — the inbox is simply unavailable until it reconnects.
  Future<void> refresh() async {
    if (!engine.isConnected) {
      _items = const [];
      _error = null;
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      _items = await engine.listMeetings();
      _error = null;
    } catch (_) {
      _error = 'Could not load the inbox.';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Retry AI enrichment for a deferred/failed capture. The engine reuses the stored transcript,
  /// so this never re-captures or duplicates. The list refreshes when the job completes.
  Future<void> retry(String meetingId) async {
    if (!engine.isConnected) return;
    try {
      await engine.reprocessMeeting(meetingId);
    } catch (_) {
      _error = 'Could not start the retry.';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_stateListener != null) engine.state.removeListener(_stateListener!);
    unawaited(_eventsSub?.cancel());
    super.dispose();
  }
}
