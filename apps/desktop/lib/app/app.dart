// Root application widget: theme, controller lifecycle, and the top-level gate between the
// Stash picker and the workspace.
//
// `app/` holds app-wide concerns (root widget, theme, shared scope). Screens live under
// `features/`. Controllers are wired to real services (filesystem, audio, transcript,
// summary); the Rust engine (`lib/ipc`) is still the intended future home for ASR/summarise.

import 'dart:async';

import 'package:flutter/material.dart';

import '../features/ask/ask_state.dart';
import '../features/editor/editor_state.dart';
import '../features/explorer/explorer_state.dart';
import '../features/listening/listening_state.dart';
import '../features/meetings/meeting_session_manager.dart';
import '../features/stash/stash_picker.dart';
import '../features/stash/stash_state.dart';
import '../features/workspace/workspace_shell.dart';
import '../ipc/engine_client.dart';
import '../services/ask/engine_ask_service.dart';
import '../services/companion/companion_window_service.dart';
import '../services/filesystem/file_watcher_service.dart';
import '../services/meeting/engine_summary_service.dart';
import '../services/meetings/meeting_detector.dart';
import '../services/meetings/meeting_settings.dart';
import '../services/notifications/notification_service.dart';
import '../services/platform/platform_capabilities.dart';
import '../services/window/window_service.dart';
import 'app_scope.dart';
import 'theme.dart';
import 'theme_controller.dart';

class NotelyApp extends StatefulWidget {
  const NotelyApp({super.key, this.engine, this.autoConnectEngine = true});

  /// Optional injected engine client (tests supply their own). When null, the app owns one.
  final EngineClient? engine;

  /// Whether to start the IPC connect loop on launch. Disabled by widget tests so they don't
  /// open real sockets/timers.
  final bool autoConnectEngine;

  @override
  State<NotelyApp> createState() => _NotelyAppState();
}

class _NotelyAppState extends State<NotelyApp> {
  // The single IPC boundary to the Rust engine. Owned by the app runtime and connected for the
  // whole session; features reach the backend only through it.
  late final EngineClient _engine = widget.engine ?? EngineClient();

  late final StashController _stash = StashController();
  late final ExplorerController _explorer = ExplorerController(
    watcher: const IoFileWatcherService(),
  );
  late final EditorController _editor = EditorController();
  // Summarisation is a real backend feature (transcript → MOM). Route it through the engine,
  // falling back to a deterministic offline summary only when the engine is unreachable.
  late final ListeningController _listening = ListeningController(
    summary: EngineSummaryService(client: _engine),
  );
  late final ThemeController _theme = ThemeController();
  // Ask is source-grounded through the engine (retrieval + local LLM), degrading to the offline
  // keyword answerer when the engine or its LLM is unavailable.
  late final AskController _ask = AskController(
    service: EngineAskService(client: _engine),
  );

  // Meeting-detection runtime. Deliberately OWNED BY THE APP RUNTIME, not gated by the main
  // window or an open stash: detection, the OS notification, and the companion overlay must keep
  // working while the main window is minimized/hidden. Native surfaces (notifications, detector,
  // companion window) degrade to no-ops on platforms/hosts without an implementation.
  final MeetingDetector _detector = PlatformMeetingDetector();
  final NotificationService _notifications = PlatformNotificationService();
  final CompanionWindowService _companion = PlatformCompanionWindowService();
  static const WindowService _window = PlatformWindowService();
  final MeetingSettingsStore _meetingSettingsStore = MeetingSettingsStore();
  final PlatformCapabilitiesService _capabilitiesService =
      PlatformCapabilitiesService();
  late final MeetingSessionManager _meetings = MeetingSessionManager(
    detector: _detector,
    notifications: _notifications,
    companion: _companion,
    listening: _listening,
    resolveActiveFile: () => _editor.openPath,
    onOpenInNotely: _window.focusMain,
  );

  String? _loadedRoot;

  @override
  void initState() {
    super.initState();
    // Keep the explorer + Ask in sync with the open stash, and restore persisted state.
    _stash.addListener(_syncExplorerRoot);
    _stash.restore();
    _theme.restore();
    _ask.restore();
    // Begin connecting to the engine. The client reconnects with capped backoff, so the app is
    // usable (and shows connection state) whether or not the engine is running yet.
    if (widget.autoConnectEngine) _engine.start();
    _startMeetingRuntime();
  }

  Future<void> _startMeetingRuntime() async {
    // Ask the OS what it can actually do; the runtime stays inert where meeting support is absent
    // (e.g. platforms whose native adapter isn't implemented yet) rather than opening dead channels.
    final capabilities = await _capabilitiesService.resolve();
    await _meetings.start(capabilities: capabilities);
    if (!capabilities.meetingDetection) return;
    // Apply persisted detection settings once the runtime is up.
    final settings = await _meetingSettingsStore.load();
    await _meetings.updateSettings(settings);
  }

  void _syncExplorerRoot() {
    final path = _stash.path;
    if (path != null && path != _loadedRoot) {
      _loadedRoot = path;
      _explorer.setRoot(path);
      _ask.setStash(path);
    } else if (path == null) {
      _loadedRoot = null;
      _ask.setStash(null);
    }
  }

  @override
  void dispose() {
    _stash.removeListener(_syncExplorerRoot);
    _stash.dispose();
    _explorer.dispose();
    _editor.dispose();
    _listening.dispose();
    _theme.dispose();
    _ask.dispose();
    _meetings.dispose();
    _detector.dispose();
    _notifications.dispose();
    _companion.dispose();
    unawaited(_engine.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _theme,
      builder: (context, _) => MaterialApp(
        title: 'notely.ai',
        debugShowCheckedModeBanner: false,
        theme: buildNotelyTheme(Brightness.light),
        darkTheme: buildNotelyTheme(Brightness.dark),
        themeMode: _theme.mode,
        home: AppScope(
          stash: _stash,
          explorer: _explorer,
          editor: _editor,
          listening: _listening,
          theme: _theme,
          ask: _ask,
          meetings: _meetings,
          engine: _engine,
          child: const _AppGate(),
        ),
      ),
    );
  }
}

/// Gates between the Stash picker and the workspace.
///
/// On first launch (no stash open) ONLY the picker is shown, over a plain background — the
/// workspace isn't mounted behind it, so the launch modal is the sole thing on screen. When a
/// stash is already open and the user is *switching*, the workspace stays mounted behind the
/// modal (subdued), matching the Obsidian open-vault feel.
class _AppGate extends StatelessWidget {
  const _AppGate();

  @override
  Widget build(BuildContext context) {
    final stash = AppScope.of(context).stash;
    return AnimatedBuilder(
      animation: stash,
      builder: (context, _) {
        final bg = context.tokens.background;
        // Avoid any flash while the persisted stash is being restored.
        if (stash.isRestoring) return ColoredBox(color: bg);
        return Stack(
          fit: StackFit.expand,
          children: [
            if (stash.isOpen) const WorkspaceShell() else ColoredBox(color: bg),
            // The meeting notification (OS-level) and the floating companion (a separate native
            // overlay window) are NOT rendered here — they live outside the main window and are
            // driven by MeetingSessionManager + the native runner.
            if (stash.showPicker) const StashPicker(),
          ],
        );
      },
    );
  }
}
