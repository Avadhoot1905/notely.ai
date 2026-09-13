// Companion overlay window abstraction.
//
// The companion is a SEPARATE, OS-level desktop window — always-on-top, transparent, frameless,
// non-activating — NOT an in-app widget. This interface is how the main app drives that native
// window: show/hide it, push the latest session state to it, and receive the user's commands
// (pause/resume/stop/open-in-Notely) back. The native side owns the window (and its second
// Flutter engine that renders the pill/popover); this keeps all of that behind one seam so the
// app layer stays platform-neutral.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the companion should render. Kept small and serializable (crosses the native boundary and
/// is relayed to the companion's own Flutter engine).
@immutable
class CompanionSnapshot {
  const CompanionSnapshot({
    required this.paused,
    required this.elapsedSeconds,
    required this.lines,
    this.meetingTitle,
  });

  final bool paused;
  final int elapsedSeconds;

  /// Recent transcript lines: each `{speaker, time, text}`.
  final List<Map<String, String>> lines;
  final String? meetingTitle;

  Map<String, dynamic> toMap() => {
    'paused': paused,
    'elapsedSeconds': elapsedSeconds,
    'lines': lines,
    if (meetingTitle != null) 'meetingTitle': meetingTitle,
  };
}

/// A command issued from the companion window back to the app.
enum CompanionCommand { pause, resume, stop, openInNotely }

abstract class CompanionWindowService {
  /// Create/show the overlay window (idempotent).
  Future<void> show();

  /// Hide/close the overlay window (idempotent). Must leave nothing floating behind.
  Future<void> hide();

  /// Push the latest session snapshot to the overlay.
  Future<void> update(CompanionSnapshot snapshot);

  /// Commands from the companion UI.
  Stream<CompanionCommand> get commands;

  Future<void> dispose();
}

/// Bridges to the native overlay window over method + event channels.
class PlatformCompanionWindowService implements CompanionWindowService {
  PlatformCompanionWindowService({MethodChannel? method, EventChannel? events})
    : _method = method ?? const MethodChannel(_methodChannelName),
      _events = events ?? const EventChannel(_eventChannelName) {
    _cmdSub = _events.receiveBroadcastStream().listen(
      _onCommand,
      onError: (Object e) {
        if (kDebugMode) debugPrint('Companion channel error: $e');
      },
    );
  }

  static const _methodChannelName = 'notely/companion';
  static const _eventChannelName = 'notely/companion/commands';

  final MethodChannel _method;
  final EventChannel _events;
  final _commands = StreamController<CompanionCommand>.broadcast();
  StreamSubscription<dynamic>? _cmdSub;

  @override
  Stream<CompanionCommand> get commands => _commands.stream;

  @override
  Future<void> show() => _invoke('show');

  @override
  Future<void> hide() => _invoke('hide');

  @override
  Future<void> update(CompanionSnapshot snapshot) =>
      _invoke('update', snapshot.toMap());

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      await _method.invokeMethod(method, args);
    } on MissingPluginException {
      // No native overlay on this platform yet — swallow.
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('Companion $method failed: ${e.message}');
    }
  }

  void _onCommand(dynamic raw) {
    final cmd = switch (raw) {
      'pause' => CompanionCommand.pause,
      'resume' => CompanionCommand.resume,
      'stop' => CompanionCommand.stop,
      'openInNotely' => CompanionCommand.openInNotely,
      _ => null,
    };
    if (cmd != null) _commands.add(cmd);
  }

  @override
  Future<void> dispose() async {
    await _cmdSub?.cancel();
    await _commands.close();
  }
}

/// No-op companion for tests/headless: records the last snapshot and visibility for assertions.
class NoopCompanionWindowService implements CompanionWindowService {
  final _commands = StreamController<CompanionCommand>.broadcast();
  bool visible = false;
  CompanionSnapshot? lastSnapshot;

  @override
  Stream<CompanionCommand> get commands => _commands.stream;

  @override
  Future<void> show() async => visible = true;

  @override
  Future<void> hide() async => visible = false;

  @override
  Future<void> update(CompanionSnapshot snapshot) async =>
      lastSnapshot = snapshot;

  void emitCommand(CompanionCommand command) {
    if (!_commands.isClosed) _commands.add(command);
  }

  @override
  Future<void> dispose() async => _commands.close();
}
