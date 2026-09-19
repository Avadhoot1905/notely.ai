// MeetingSessionManager — the single source of truth for meeting detection + the companion.
//
// Owns the whole lifecycle, decoupled from the widget tree so it keeps working while the main
// window is minimized/hidden:
//
//   notRunning ─detect─▶ awaitingDecision ─dismiss─▶ notRunning
//                              │
//                            start (notification action / auto-track / companion)
//                              ▼
//                          tracking ──meeting ends / stop──▶ finalizing ──▶ notRunning
//
// It wires the detector → native notification → (on accept) the [ListeningController] session +
// the native companion window, and relays companion commands back to the session. Both the main
// window and the companion window observe THIS — they never hold independent copies of meeting
// state. Deduplication prevents notification spam and re-nagging a dismissed meeting.

// Named required params bind to private fields (`_x = x`); named args can't start with `_`, so
// `prefer_initializing_formals` can't apply here.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/companion/companion_window_service.dart';
import '../../services/meetings/meeting_detector.dart';
import '../../services/meetings/meeting_event.dart';
import '../../services/meetings/meeting_settings.dart';
import '../../services/notifications/notification_service.dart';
import '../../services/platform/platform_capabilities.dart';
import '../listening/listening_state.dart';
import 'companion_controller.dart';

enum MeetingRuntimeState { notRunning, awaitingDecision, tracking, finalizing }

class MeetingSessionManager extends ChangeNotifier {
  MeetingSessionManager({
    required MeetingDetector detector,
    required NotificationService notifications,
    required CompanionWindowService companion,
    required ListeningController listening,
    MeetingDetectionSettings settings = const MeetingDetectionSettings(),
    String? Function()? resolveActiveFile,
    VoidCallback? onOpenInNotely,
  }) : _detector = detector,
       _notifications = notifications,
       _companion = companion,
       _listening = listening,
       _settings = settings,
       _resolveActiveFile = resolveActiveFile,
       _onOpenInNotely = onOpenInNotely {
    // The companion is a projection of THIS session's live meeting state — it owns only its own
    // presentation state, never a second copy of the meeting.
    _companionController = CompanionController(
      window: _companion,
      source: _listening,
      liveState: () => _listening.liveState,
      elapsed: () => _listening.elapsed,
      title: () => _active?.title ?? _active?.provider.displayName,
    );
  }

  final MeetingDetector _detector;
  final NotificationService _notifications;
  final CompanionWindowService _companion;
  final ListeningController _listening;
  late final CompanionController _companionController;

  MeetingDetectionSettings _settings;
  final String? Function()? _resolveActiveFile;
  final VoidCallback? _onOpenInNotely;

  /// What the current OS can actually do. Set from [start]; defaults to fully-capable so unit
  /// tests exercise the whole flow. On an unsupported platform the runtime stays inert.
  PlatformCapabilities _capabilities = _fullyCapable;

  static const _fullyCapable = PlatformCapabilities(
    meetingDetection: true,
    microphoneActivitySignal: true,
    nativeNotifications: true,
    notificationActions: true,
    companionOverlay: true,
    alwaysOnTop: true,
    transparentWindow: true,
    nonActivatingOverlay: true,
    backgroundRuntime: true,
  );

  PlatformCapabilities get capabilities => _capabilities;

  StreamSubscription<MeetingDetectedEvent>? _detSub;
  StreamSubscription<MeetingEndedEvent>? _endSub;
  StreamSubscription<NotificationAction>? _actionSub;
  StreamSubscription<CompanionCommand>? _cmdSub;

  MeetingRuntimeState _state = MeetingRuntimeState.notRunning;
  MeetingDetectedEvent? _awaiting; // shown a notification, not yet answered
  MeetingDetectedEvent? _active; // currently tracked

  /// Keys we've already surfaced (notified/auto-started) so re-observations don't re-notify.
  final Set<String> _seen = {};

  /// Keys the user explicitly dismissed — never nag again for the same meeting.
  final Set<String> _dismissed = {};

  MeetingRuntimeState get state => _state;
  MeetingDetectedEvent? get activeMeeting => _active;
  MeetingDetectedEvent? get awaitingMeeting => _awaiting;
  MeetingDetectionSettings get settings => _settings;
  bool get isTracking => _state == MeetingRuntimeState.tracking;

  /// Begin the background runtime: request permission, clear any stale overlay, watch for
  /// meetings, and relay notification/companion/session events.
  ///
  /// [capabilities] describes what the current OS supports; when meeting detection isn't available
  /// (e.g. the platform's native adapter isn't implemented yet) the runtime stays fully inert
  /// instead of opening dead channels — honest degradation, not a silent no-op storm.
  Future<void> start({PlatformCapabilities? capabilities}) async {
    if (capabilities != null) _capabilities = capabilities;

    // The companion mirrors the listening session — whether it was started by the Listen button or
    // by meeting detection — so wire the overlay + observe the session even when DETECTION isn't
    // available on this platform.
    if (_capabilities.companionOverlay) {
      await _companion.hide(); // clear any overlay left by a crash/previous run
      _cmdSub = _companion.commands.listen(_onCompanionCommand);
    }
    _listening.addListener(_onListeningChanged);

    if (!_capabilities.meetingDetection) return;

    if (_capabilities.nativeNotifications) {
      await _notifications.requestPermission();
      _actionSub = _notifications.actions.listen(_onNotificationAction);
    }
    _detSub = _detector.detections.listen(_onDetected);
    _endSub = _detector.endings.listen(_onEnded);

    await _detector.start(enabledProviders: _settings.enabledProviders);
  }

  Future<void> updateSettings(MeetingDetectionSettings settings) async {
    _settings = settings;
    if (!_capabilities.meetingDetection) return;
    await _detector.start(enabledProviders: settings.enabledProviders);
    if (_capabilities.companionOverlay &&
        _state == MeetingRuntimeState.tracking) {
      if (settings.showCompanion) {
        await _companionController.show();
      } else {
        await _companionController.hide();
      }
    }
    notifyListeners();
  }

  // ── Detection ──────────────────────────────────────────────────────────────
  Future<void> _onDetected(MeetingDetectedEvent event) async {
    final key = event.meetingKey;
    // Dedup: ignore the meeting we're already handling, already surfaced, or already dismissed.
    if (_dismissed.contains(key)) return;
    if (_active?.meetingKey == key || _awaiting?.meetingKey == key) return;
    if (_seen.contains(key)) return;
    // Don't interrupt an in-progress tracked meeting with a prompt for another.
    if (_state == MeetingRuntimeState.tracking) return;

    _seen.add(key);

    if (_settings.autoStartTracking) {
      await _startTracking(event);
      return;
    }
    if (!_settings.notifyOnDetect) return;

    _awaiting = event;
    _state = MeetingRuntimeState.awaitingDecision;
    notifyListeners();
    await _notifications.showMeetingPrompt(
      meetingKey: key,
      title: "You're in a meeting",
      body:
          'Want Notely to track notes for this ${event.provider.displayName} meeting?',
    );
  }

  Future<void> _onNotificationAction(NotificationAction action) async {
    final awaiting = _awaiting;
    if (awaiting == null || awaiting.meetingKey != action.meetingKey) {
      // Late/duplicate action — clear the notification and move on.
      await _notifications.cancel(action.meetingKey);
      return;
    }
    switch (action.type) {
      case NotificationActionType.start:
        await _startTracking(awaiting);
      case NotificationActionType.dismiss:
        _dismissed.add(awaiting.meetingKey);
        _awaiting = null;
        _state = MeetingRuntimeState.notRunning;
        await _notifications.cancel(action.meetingKey);
        notifyListeners();
    }
  }

  // ── Tracking ─────────────────────────────────────────────────────────────
  Future<void> _startTracking(MeetingDetectedEvent event) async {
    _awaiting = null;
    _active = event;
    _state = MeetingRuntimeState.tracking;
    notifyListeners();

    await _notifications.cancel(event.meetingKey);
    await _listening.start(activeFilePath: _resolveActiveFile?.call());

    if (_settings.showCompanion && _capabilities.companionOverlay) {
      // The controller pushes the live-state projection reactively and ticks the elapsed clock.
      await _companionController.show();
    }
  }

  Future<void> _onEnded(MeetingEndedEvent ended) async {
    final active = _active;
    if (active == null) return;
    // An empty key means "the active meeting ended"; otherwise it must match.
    if (ended.meetingKey.isNotEmpty && ended.meetingKey != active.meetingKey) {
      return;
    }
    await _finalize();
  }

  /// Stop capture, hide the companion, and return to idle — without discarding the transcript
  /// (it stays in the listening controller's Review state for the user to summarise/persist).
  Future<void> _finalize() async {
    if (_state != MeetingRuntimeState.tracking) return;
    _state = MeetingRuntimeState.finalizing;
    notifyListeners();

    await _listening
        .stop(); // → Reviewing; transcript retained for persistence.
    await _companionController.hide();

    final key = _active?.meetingKey;
    if (key != null) {
      _seen.remove(key);
      _dismissed.remove(key);
    }
    _active = null;
    _state = MeetingRuntimeState.notRunning;
    notifyListeners();
  }

  // ── Companion commands ───────────────────────────────────────────────────
  Future<void> _onCompanionCommand(CompanionCommand command) async {
    switch (command) {
      case CompanionCommand.pause:
        await _listening.pause();
      case CompanionCommand.resume:
        await _listening.resume();
      case CompanionCommand.stop:
        await _finalize();
      case CompanionCommand.openInNotely:
        _onOpenInNotely?.call();
    }
  }

  // ── Session → companion sync ─────────────────────────────────────────────
  void _onListeningChanged() {
    final active = _listening.isListening || _listening.isPaused;
    if (_state == MeetingRuntimeState.tracking) {
      // Detected-meeting flow: reconcile if the session ended via the main UI. Snapshots are pushed
      // reactively by the CompanionController; visibility was already set by _startTracking.
      if (!active) _finalize();
      return;
    }
    // Manual (non-detected) listening: the companion appears whenever listening starts and hides
    // when it stops.
    unawaited(_syncManualCompanion(active));
  }

  /// Mirror companion visibility to a manually-started listening session (Listen button).
  Future<void> _syncManualCompanion(bool active) async {
    if (!_capabilities.companionOverlay || !_settings.showCompanion) return;
    if (active && !_companionController.state.isVisible) {
      await _companionController.show();
    } else if (!active && _companionController.state.isVisible) {
      await _companionController.hide();
    }
  }

  @override
  void dispose() {
    _companionController.dispose();
    _detSub?.cancel();
    _endSub?.cancel();
    _actionSub?.cancel();
    _cmdSub?.cancel();
    _listening.removeListener(_onListeningChanged);
    super.dispose();
  }
}
