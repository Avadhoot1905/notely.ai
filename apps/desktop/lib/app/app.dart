// Root application widget: theme, controller lifecycle, and the top-level gate between the
// Stash picker and the workspace.
//
// `app/` holds app-wide concerns (root widget, theme, shared scope). Screens live under
// `features/`. Controllers are wired to real services (filesystem, audio, transcript,
// summary); the Rust engine (`lib/ipc`) is still the intended future home for ASR/summarise.

import 'package:flutter/material.dart';

import '../features/editor/editor_state.dart';
import '../features/explorer/explorer_state.dart';
import '../features/listening/listening_state.dart';
import '../features/stash/stash_picker.dart';
import '../features/stash/stash_state.dart';
import '../features/workspace/workspace_shell.dart';
import 'app_scope.dart';
import 'theme.dart';

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

  String? _loadedRoot;

  @override
  void initState() {
    super.initState();
    // Keep the explorer's root in sync with the open stash, and restore the last stash.
    _stash.addListener(_syncExplorerRoot);
    _stash.restore();
  }

  void _syncExplorerRoot() {
    final path = _stash.path;
    if (path != null && path != _loadedRoot) {
      _loadedRoot = path;
      _explorer.setRoot(path);
    } else if (path == null) {
      _loadedRoot = null;
    }
  }

  @override
  void dispose() {
    _stash.removeListener(_syncExplorerRoot);
    _stash.dispose();
    _explorer.dispose();
    _editor.dispose();
    _listening.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notely',
      debugShowCheckedModeBanner: false,
      theme: buildNotelyTheme(),
      home: AppScope(
        stash: _stash,
        explorer: _explorer,
        editor: _editor,
        listening: _listening,
        child: const _AppGate(),
      ),
    );
  }
}

/// Shows the workspace with the Stash picker layered above it until a stash is open.
class _AppGate extends StatelessWidget {
  const _AppGate();

  @override
  Widget build(BuildContext context) {
    final stash = AppScope.of(context).stash;
    return AnimatedBuilder(
      animation: stash,
      builder: (context, _) {
        return Stack(
          children: [
            // The workspace is always mounted so it reads as "subdued behind the modal",
            // matching the Obsidian open-vault feel. It's inert until a stash is open.
            const WorkspaceShell(),
            // While restoring the persisted stash, keep the picker hidden to avoid a flash.
            if (!stash.isOpen && !stash.isRestoring) const StashPicker(),
          ],
        );
      },
    );
  }
}
