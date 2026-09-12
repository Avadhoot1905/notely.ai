// Root application widget: theme, controller lifecycle, and the top-level gate between the
// Stash picker and the workspace.
//
// `app/` holds app-wide concerns (root widget, theme, shared scope). Screens live under
// `features/`. Controllers are wired to real services (filesystem, audio, transcript,
// summary); the Rust engine (`lib/ipc`) is still the intended future home for ASR/summarise.

import 'package:flutter/material.dart';

import '../features/ask/ask_state.dart';
import '../features/calls/call_detection_state.dart';
import '../features/calls/call_notes_prompt.dart';
import '../features/editor/editor_state.dart';
import '../features/explorer/explorer_state.dart';
import '../features/listening/listening_overlay.dart';
import '../features/listening/listening_state.dart';
import '../features/stash/stash_picker.dart';
import '../features/stash/stash_state.dart';
import '../features/workspace/workspace_shell.dart';
import 'app_scope.dart';
import 'theme.dart';
import 'theme_controller.dart';

class NotelyApp extends StatefulWidget {
  const NotelyApp({super.key});

  @override
  State<NotelyApp> createState() => _NotelyAppState();
}

class _NotelyAppState extends State<NotelyApp> {
  late final StashController _stash = StashController();
  late final ExplorerController _explorer = ExplorerController();
  late final EditorController _editor = EditorController();
  late final ListeningController _listening = ListeningController();
  late final ThemeController _theme = ThemeController();
  late final AskController _ask = AskController();
  late final CallDetectionController _callDetection = CallDetectionController();

  String? _loadedRoot;

  @override
  void initState() {
    super.initState();
    // Keep the explorer + Ask in sync with the open stash, and restore persisted state.
    _stash.addListener(_syncExplorerRoot);
    _stash.restore();
    _theme.restore();
    _ask.restore();
  }

  void _syncExplorerRoot() {
    final path = _stash.path;
    if (path != null && path != _loadedRoot) {
      _loadedRoot = path;
      _explorer.setRoot(path);
      _ask.setStash(path);
      // Once a stash is open, watch for calls so we can offer to take notes.
      _callDetection.start();
    } else if (path == null) {
      _loadedRoot = null;
      _ask.setStash(null);
      _callDetection.stop();
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
    _callDetection.dispose();
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
          callDetection: _callDetection,
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
            // Call-notes prompt + the floating "listening" widget live above the workspace but
            // below the picker, so switching stashes always draws over them.
            if (stash.isOpen) const ListeningOverlay(),
            if (stash.isOpen) const CallNotesPrompt(),
            if (stash.showPicker) const StashPicker(),
          ],
        );
      },
    );
  }
}
