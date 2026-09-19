// Tests for MeetingSessionManager: the detection → notification → tracking → end lifecycle,
// deduplication, companion visibility/commands, and auto-track / provider gating. All native
// surfaces (detector, notifications, companion) are faked so this runs headless.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/listening/listening_state.dart';
import 'package:notely_desktop/features/meetings/meeting_session_manager.dart';
import 'package:notely_desktop/services/companion/companion_window_service.dart';
import 'package:notely_desktop/services/meetings/meeting_detector.dart';
import 'package:notely_desktop/services/meetings/meeting_event.dart';
import 'package:notely_desktop/services/meetings/meeting_settings.dart';
import 'package:notely_desktop/services/meeting/summary_service.dart';
import 'package:notely_desktop/services/notifications/notification_service.dart';
import 'package:notely_desktop/services/platform/platform_capabilities.dart';
import 'package:notely_desktop/services/transcript/transcript_service.dart';

import 'session_test.dart' show FakeAudioService;

/// Notification fake that records what was shown/cancelled and lets a test drive user actions.
class RecordingNotificationService implements NotificationService {
  final List<String> shown = [];
  final List<String> cancelled = [];
  final _actions = StreamController<NotificationAction>.broadcast();

  @override
  Stream<NotificationAction> get actions => _actions.stream;
  @override
  Future<NotificationPermission> requestPermission() async =>
      NotificationPermission.granted;
  @override
  Future<void> showMeetingPrompt({
    required String meetingKey,
    required String title,
    required String body,
  }) async => shown.add(meetingKey);
  @override
  Future<void> cancel(String meetingKey) async => cancelled.add(meetingKey);
  void emit(String meetingKey, NotificationActionType type) =>
      _actions.add(NotificationAction(meetingKey: meetingKey, type: type));
  @override
  Future<void> dispose() async => _actions.close();
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  late MockMeetingDetector detector;
  late RecordingNotificationService notifications;
  late NoopCompanionWindowService companion;
  late ListeningController listening;
  late MeetingSessionManager manager;

  ListeningController makeListening() => ListeningController(
    audio: FakeAudioService(),
    transcript: MockTranscriptService(interval: const Duration(seconds: 30)),
    summary: const MockSummaryService(),
  );

  MeetingSessionManager makeManager({
    MeetingDetectionSettings settings = const MeetingDetectionSettings(),
  }) {
    return MeetingSessionManager(
      detector: detector,
      notifications: notifications,
      companion: companion,
      listening: listening,
      settings: settings,
    );
  }

  MeetingDetectedEvent event({
    MeetingProvider provider = MeetingProvider.zoom,
    String? meetingId = 'abc',
    String? title = 'Standup',
  }) => MeetingDetectedEvent(
    provider: provider,
    startedAt: DateTime(2026, 1, 1, 10),
    meetingId: meetingId,
    title: title,
  );

  setUp(() {
    detector = MockMeetingDetector();
    notifications = RecordingNotificationService();
    companion = NoopCompanionWindowService();
    listening = makeListening();
  });

  tearDown(() {
    manager.dispose();
    listening.dispose();
    detector.dispose();
    notifications.dispose();
    companion.dispose();
  });

  test('detect → notify → start → tracking, companion shown', () async {
    manager = makeManager();
    await manager.start();

    detector.emitDetected(event());
    await _pump();
    expect(manager.state, MeetingRuntimeState.awaitingDecision);
    expect(notifications.shown, ['zoom:abc']);
    expect(companion.visible, isFalse); // no companion until accepted

    notifications.emit('zoom:abc', NotificationActionType.start);
    await _pump();
    expect(manager.state, MeetingRuntimeState.tracking);
    expect(listening.isListening, isTrue);
    expect(companion.visible, isTrue);
    expect(notifications.cancelled, contains('zoom:abc'));
  });

  test(
    'manual listening (no meeting detected) shows the companion, hides on stop',
    () async {
      manager = makeManager();
      await manager.start(); // full capabilities by default; nothing detected

      // The Listen button starts the session directly on the ListeningController.
      await listening.start();
      await _pump();
      expect(
        manager.state,
        MeetingRuntimeState.notRunning,
        reason: 'never entered detection tracking',
      );
      expect(
        companion.visible,
        isTrue,
        reason: 'companion appears whenever listening starts',
      );

      await listening.stop();
      await _pump();
      expect(
        companion.visible,
        isFalse,
        reason: 'and hides when listening stops',
      );
    },
  );

  test('dismiss → notRunning and never re-nags the same meeting', () async {
    manager = makeManager();
    await manager.start();

    detector.emitDetected(event());
    await _pump();
    notifications.emit('zoom:abc', NotificationActionType.dismiss);
    await _pump();
    expect(manager.state, MeetingRuntimeState.notRunning);
    expect(listening.isListening, isFalse);

    // Same meeting re-observed → no second notification.
    detector.emitDetected(event());
    await _pump();
    expect(notifications.shown, ['zoom:abc']); // still just one
    expect(manager.state, MeetingRuntimeState.notRunning);
  });

  test('duplicate detections do not spam notifications', () async {
    manager = makeManager();
    await manager.start();

    for (var i = 0; i < 5; i++) {
      detector.emitDetected(event());
      await _pump();
    }
    expect(notifications.shown, ['zoom:abc']);
  });

  test('meeting end while tracking finalizes and hides companion', () async {
    manager = makeManager();
    await manager.start();

    detector.emitDetected(event());
    await _pump();
    notifications.emit('zoom:abc', NotificationActionType.start);
    await _pump();
    expect(manager.state, MeetingRuntimeState.tracking);

    detector.emitEnded(const MeetingEndedEvent(meetingKey: 'zoom:abc'));
    await _pump();
    expect(manager.state, MeetingRuntimeState.notRunning);
    expect(companion.visible, isFalse);
    // Transcript retained for review (not discarded).
    expect(listening.isReviewing, isTrue);
  });

  test(
    'companion stop command finalizes; pause/resume relay to session',
    () async {
      manager = makeManager();
      await manager.start();
      detector.emitDetected(event());
      await _pump();
      notifications.emit('zoom:abc', NotificationActionType.start);
      await _pump();

      companion.emitCommand(CompanionCommand.pause);
      await _pump();
      expect(listening.isPaused, isTrue);

      companion.emitCommand(CompanionCommand.resume);
      await _pump();
      expect(listening.isListening, isTrue);

      companion.emitCommand(CompanionCommand.stop);
      await _pump();
      expect(manager.state, MeetingRuntimeState.notRunning);
      expect(companion.visible, isFalse);
    },
  );

  test('auto-start setting skips the notification', () async {
    manager = makeManager(
      settings: const MeetingDetectionSettings(autoStartTracking: true),
    );
    await manager.start();

    detector.emitDetected(event());
    await _pump();
    expect(notifications.shown, isEmpty);
    expect(manager.state, MeetingRuntimeState.tracking);
    expect(companion.visible, isTrue);
  });

  test('disabled provider is not surfaced', () async {
    manager = makeManager(
      settings: const MeetingDetectionSettings(
        enabledProviders: {MeetingProvider.teams},
      ),
    );
    await manager.start();

    // Detector was told only Teams is enabled; a Zoom event is filtered at the source.
    detector.emitDetected(event(provider: MeetingProvider.zoom));
    await _pump();
    expect(notifications.shown, isEmpty);
    expect(manager.state, MeetingRuntimeState.notRunning);
  });

  test(
    'unsupported platform: runtime stays inert (no detection/notification)',
    () async {
      manager = makeManager();
      // Windows/Linux fallback has meetingDetection == false.
      await manager.start(
        capabilities: PlatformCapabilities.fallback(TargetPlatform.windows),
      );

      detector.emitDetected(event());
      await _pump();
      // Detector events are never subscribed to when detection is unsupported.
      expect(notifications.shown, isEmpty);
      expect(manager.state, MeetingRuntimeState.notRunning);
      expect(companion.visible, isFalse);
    },
  );

  test(
    'detection without overlay support: tracks but shows no companion',
    () async {
      manager = makeManager();
      await manager.start(
        capabilities: const PlatformCapabilities(
          meetingDetection: true,
          microphoneActivitySignal: true,
          nativeNotifications: true,
          notificationActions: true,
          companionOverlay:
              false, // e.g. a platform where the overlay isn't available
          alwaysOnTop: false,
          transparentWindow: false,
          nonActivatingOverlay: false,
          backgroundRuntime: true,
        ),
      );

      detector.emitDetected(event());
      await _pump();
      notifications.emit('zoom:abc', NotificationActionType.start);
      await _pump();
      expect(manager.state, MeetingRuntimeState.tracking);
      expect(listening.isListening, isTrue);
      expect(companion.visible, isFalse); // no overlay attempted
    },
  );

  test('companion receives session snapshots while tracking', () async {
    manager = makeManager();
    await manager.start();
    detector.emitDetected(event());
    await _pump();
    notifications.emit('zoom:abc', NotificationActionType.start);
    await _pump();

    expect(companion.lastSnapshot, isNotNull);
    expect(companion.lastSnapshot!.paused, isFalse);
    expect(companion.lastSnapshot!.meetingTitle, 'Standup');
  });
}
