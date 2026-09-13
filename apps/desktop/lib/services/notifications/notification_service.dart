// Native OS notification abstraction.
//
// This is the *real* OS notification path (Notification Center / Action Center / libnotify), not
// an in-app banner — so a meeting prompt reaches the user even when the Notely window is closed,
// minimized, or unfocused. The shared app layer calls [showMeetingPrompt] and listens to
// [actions]; each platform maps that onto its native API behind [PlatformNotificationService].
//
// A meeting prompt carries "Start tracking" and "Dismiss" actions; the chosen action comes back
// on [actions] keyed by the same meetingKey, so the session manager can react without the UI
// being mounted.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which button the user pressed on a meeting notification. [body] (clicking the notification
/// itself) is treated as [start] — the primary intent.
enum NotificationActionType { start, dismiss }

@immutable
class NotificationAction {
  const NotificationAction({required this.meetingKey, required this.type});
  final String meetingKey;
  final NotificationActionType type;
}

/// Availability of the OS notification capability.
enum NotificationPermission { granted, denied, notDetermined, unsupported }

abstract class NotificationService {
  /// Ask the OS for notification permission (idempotent; returns the resulting state).
  Future<NotificationPermission> requestPermission();

  /// Show the "you're in a meeting — track notes?" prompt with Start/Dismiss actions.
  Future<void> showMeetingPrompt({
    required String meetingKey,
    required String title,
    required String body,
  });

  /// Remove any pending notification for [meetingKey] (e.g. after the meeting ends).
  Future<void> cancel(String meetingKey);

  /// User responses to shown notifications.
  Stream<NotificationAction> get actions;

  Future<void> dispose();
}

/// Bridges to native notifications over method + event channels.
class PlatformNotificationService implements NotificationService {
  PlatformNotificationService({MethodChannel? method, EventChannel? events})
    : _method = method ?? const MethodChannel(_methodChannelName),
      _events = events ?? const EventChannel(_eventChannelName) {
    _actionSub = _events.receiveBroadcastStream().listen(
      _onNativeAction,
      onError: (Object e) {
        if (kDebugMode) debugPrint('Notification channel error: $e');
      },
    );
  }

  static const _methodChannelName = 'notely/notifications';
  static const _eventChannelName = 'notely/notifications/actions';

  final MethodChannel _method;
  final EventChannel _events;
  final _actions = StreamController<NotificationAction>.broadcast();
  StreamSubscription<dynamic>? _actionSub;

  @override
  Stream<NotificationAction> get actions => _actions.stream;

  @override
  Future<NotificationPermission> requestPermission() async {
    try {
      final res = await _method.invokeMethod<String>('requestPermission');
      return switch (res) {
        'granted' => NotificationPermission.granted,
        'denied' => NotificationPermission.denied,
        'notDetermined' => NotificationPermission.notDetermined,
        _ => NotificationPermission.unsupported,
      };
    } on MissingPluginException {
      return NotificationPermission.unsupported;
    } on PlatformException {
      return NotificationPermission.denied;
    }
  }

  @override
  Future<void> showMeetingPrompt({
    required String meetingKey,
    required String title,
    required String body,
  }) async {
    try {
      await _method.invokeMethod('showMeetingPrompt', {
        'meetingKey': meetingKey,
        'title': title,
        'body': body,
      });
    } on MissingPluginException {
      // No native notifications on this platform — swallow (capability reported elsewhere).
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('showMeetingPrompt failed: ${e.message}');
    }
  }

  @override
  Future<void> cancel(String meetingKey) async {
    try {
      await _method.invokeMethod('cancel', {'meetingKey': meetingKey});
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // ignore
    }
  }

  void _onNativeAction(dynamic raw) {
    if (raw is! Map) return;
    final key = raw['meetingKey'] as String?;
    if (key == null) return;
    final type = raw['action'] == 'start'
        ? NotificationActionType.start
        : NotificationActionType.dismiss;
    _actions.add(NotificationAction(meetingKey: key, type: type));
  }

  @override
  Future<void> dispose() async {
    await _actionSub?.cancel();
    await _actions.close();
  }
}

/// No-op notifications for tests/headless: records nothing, and lets tests drive [actions].
class NoopNotificationService implements NotificationService {
  final _actions = StreamController<NotificationAction>.broadcast();

  @override
  Stream<NotificationAction> get actions => _actions.stream;

  @override
  Future<NotificationPermission> requestPermission() async =>
      NotificationPermission.unsupported;

  @override
  Future<void> showMeetingPrompt({
    required String meetingKey,
    required String title,
    required String body,
  }) async {}

  @override
  Future<void> cancel(String meetingKey) async {}

  /// Test hook: simulate the user pressing a notification button.
  void emitAction(NotificationAction action) {
    if (!_actions.isClosed) _actions.add(action);
  }

  @override
  Future<void> dispose() async => _actions.close();
}
