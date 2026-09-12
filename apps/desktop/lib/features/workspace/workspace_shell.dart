// The main three-region desktop layout: title bar, (sidebar | editor | transcript), status bar.
//
// The transcript region does NOT exist in the normal state; it slides in only while listening
// is active, and the editor reflows to make room. Narrow windows shrink the transcript toward
// its minimum and keep the editor usable.

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../mock/mock_files.dart';
import '../editor/markdown_editor.dart';
import '../explorer/explorer_state.dart';
import '../explorer/file_tree.dart';
import '../listening/listening_button.dart';
import '../listening/transcript_panel.dart';

class WorkspaceShell extends StatelessWidget {
  const WorkspaceShell({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return Scaffold(
      backgroundColor: NotelyColors.window,
      body: Column(
        children: [
          const _TitleBar(),
          Expanded(
            child: Row(
              children: [
                const SizedBox(
                  width: NotelyDims.sidebarWidth,
                  child: _Sidebar(),
                ),
                const _VerticalDivider(),
                Expanded(
                  child: AnimatedBuilder(
                    animation: scope.listening,
                    builder: (context, _) {
                      final listening = scope.listening.startListening;
                      return LayoutBuilder(
                        builder: (context, constraints) {
                          // Shrink the transcript toward its minimum on narrow windows so
                          // the editor stays usable; never let it crush the editor below
                          // ~420px.
                          final available = constraints.maxWidth;
                          final panelW = available < 760
                              ? NotelyDims.transcriptMinWidth
                              : NotelyDims.transcriptWidth;
                          return Row(
                            children: [
                              const Expanded(child: MarkdownEditor()),
                              // Animate the occupied width while the panel itself stays laid
                              // out at a fixed width, so its content never reflows (and never
                              // momentarily overflows) during the slide in/out. ClipRect hides
                              // the part not yet revealed.
                              ClipRect(
                                child: AnimatedAlign(
                                  alignment: Alignment.centerLeft,
                                  duration: NotelyDims.panelAnim,
                                  curve: Curves.easeOutCubic,
                                  widthFactor: listening ? 1.0 : 0.0,
                                  child: SizedBox(
                                    width: panelW,
                                    // Mount the panel (and its repeating indicator) only
                                    // while listening so the idle UI fully settles.
                                    child: listening
                                        ? const TranscriptPanel()
                                        : null,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const _StatusBar(),
        ],
      ),
    );
  }
}

/// Resolve the display name of the currently selected note by walking the tree.
String? _selectedNoteName(ExplorerController explorer) {
  final id = explorer.selectedNoteId;
  if (id == null) return null;
  String? found;
  void walk(List<FileNode> nodes) {
    for (final n in nodes) {
      if (!n.isFolder && n.noteId == id) found = n.name;
      if (n.isFolder) walk(n.children);
    }
  }

  walk(explorer.roots);
  return found;
}

// ─────────────────────────────────────────────────────────────────────────────
// Title bar
// ─────────────────────────────────────────────────────────────────────────────
class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return Container(
      height: NotelyDims.titleBarHeight,
      decoration: const BoxDecoration(
        color: NotelyColors.window,
        border: Border(bottom: BorderSide(color: NotelyColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Icon(Icons.menu, size: 16, color: NotelyColors.textFaint),
          const SizedBox(width: 14),
          AnimatedBuilder(
            animation: scope.stash,
            builder: (context, _) => Text(
              scope.stash.name ?? 'Notely',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: NotelyColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(width: 1, height: 16, color: NotelyColors.border),
          const SizedBox(width: 10),
          Expanded(
            child: AnimatedBuilder(
              animation: Listenable.merge([scope.explorer]),
              builder: (context, _) {
                final name = _selectedNoteName(scope.explorer);
                return Text(
                  name ?? 'No note open',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: name == null
                        ? NotelyColors.textFaint
                        : NotelyColors.textSecondary,
                  ),
                );
              },
            ),
          ),
          const Icon(Icons.more_horiz, size: 18, color: NotelyColors.textFaint),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sidebar
// ─────────────────────────────────────────────────────────────────────────────
class _Sidebar extends StatefulWidget {
  const _Sidebar();

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  bool _searchOpen = false;
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggleSearch(ExplorerController explorer) {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _search.clear();
        explorer.setQuery('');
      }
    });
  }

  void _newNote() {
    final scope = AppScope.of(context);
    final id = scope.explorer.createNote('Untitled');
    scope.editor.open(id);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final explorer = scope.explorer;
    return Container(
      color: NotelyColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Stash header.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: AnimatedBuilder(
                    animation: scope.stash,
                    builder: (context, _) => Text(
                      (scope.stash.name ?? 'Stash').toUpperCase(),
                      style: const TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.0,
                        fontWeight: FontWeight.w700,
                        color: NotelyColors.textSecondary,
                      ),
                    ),
                  ),
                ),
                _iconBtn(Icons.search, 'Search', () => _toggleSearch(explorer)),
                _iconBtn(Icons.add, 'New note', _newNote),
                _iconBtn(Icons.swap_horiz, 'Switch Stash', scope.stash.close),
              ],
            ),
          ),
          // Listening control.
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: ListeningButton(),
          ),
          if (_searchOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                controller: _search,
                autofocus: true,
                onChanged: explorer.setQuery,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: NotelyColors.textPrimary,
                ),
                cursorColor: NotelyColors.accent,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Filter notes…',
                  hintStyle: const TextStyle(
                    color: NotelyColors.textFaint,
                    fontSize: 12.5,
                  ),
                  filled: true,
                  fillColor: NotelyColors.window,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 14,
                    color: NotelyColors.textFaint,
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 30),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(NotelyDims.radius),
                    borderSide: const BorderSide(color: NotelyColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(NotelyDims.radius),
                    borderSide: const BorderSide(color: NotelyColors.accent),
                  ),
                ),
              ),
            ),
          const Divider(height: 1, color: NotelyColors.border),
          const Expanded(child: FileTree()),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 15, color: NotelyColors.textFaint),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Status bar
// ─────────────────────────────────────────────────────────────────────────────
class _StatusBar extends StatelessWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return Container(
      height: NotelyDims.statusBarHeight,
      decoration: const BoxDecoration(
        color: NotelyColors.window,
        border: Border(top: BorderSide(color: NotelyColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: scope.stash,
            builder: (context, _) => _item(scope.stash.name ?? '—'),
          ),
          const Spacer(),
          _item('Markdown'),
          const SizedBox(width: 18),
          _item('UTF-8'),
          const SizedBox(width: 18),
          AnimatedBuilder(
            animation: scope.editor,
            builder: (context, _) => _item(
              scope.editor.hasOpenNote
                  ? 'Ln ${scope.editor.line}, Col ${scope.editor.col}'
                  : 'Ln —, Col —',
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(String text) => Text(
    text,
    style: const TextStyle(fontSize: 11, color: NotelyColors.textFaint),
  );
}

class _VerticalDivider extends StatelessWidget {
  const _VerticalDivider();

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, color: NotelyColors.border);
}
