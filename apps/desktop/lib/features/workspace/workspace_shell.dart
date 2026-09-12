// The main three-region desktop layout: title bar, (sidebar | editor | transcript), status bar.
//
// The transcript region does NOT exist in the normal state; it slides in for any active
// session (listening / paused / reviewing) and the editor reflows to make room. Narrow windows
// shrink the transcript toward its minimum and keep the editor usable.

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../editor/editor_state.dart';
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
    return _ErrorListener(
      child: Scaffold(
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
                        final showTranscript = scope.listening.showTranscript;
                        return LayoutBuilder(
                          builder: (context, constraints) {
                            // Shrink the transcript toward its minimum on narrow windows so
                            // the editor stays usable.
                            final available = constraints.maxWidth;
                            final panelW = available < 760
                                ? NotelyDims.transcriptMinWidth
                                : NotelyDims.transcriptWidth;
                            return Row(
                              children: [
                                const Expanded(child: MarkdownEditor()),
                                // Animate occupied width while the panel stays laid out at a
                                // fixed width, so its content never reflows during the slide.
                                ClipRect(
                                  child: AnimatedAlign(
                                    alignment: Alignment.centerLeft,
                                    duration: NotelyDims.panelAnim,
                                    curve: Curves.easeOutCubic,
                                    widthFactor: showTranscript ? 1.0 : 0.0,
                                    child: SizedBox(
                                      width: panelW,
                                      child: showTranscript
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
      ),
    );
  }
}

/// Display name of the open note: the basename of the editor's open path.
String? _openNoteName(EditorController editor) {
  final path = editor.openPath;
  return path == null ? null : p.basename(path);
}

// ─────────────────────────────────────────────────────────────────────────────
// Error toasts — surface filesystem/editor errors non-intrusively.
// ─────────────────────────────────────────────────────────────────────────────
class _ErrorListener extends StatefulWidget {
  const _ErrorListener({required this.child});
  final Widget child;

  @override
  State<_ErrorListener> createState() => _ErrorListenerState();
}

class _ErrorListenerState extends State<_ErrorListener> {
  ExplorerController? _explorer;
  EditorController? _editor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    if (_explorer != scope.explorer) {
      _explorer?.removeListener(_check);
      _explorer = scope.explorer..addListener(_check);
    }
    if (_editor != scope.editor) {
      _editor?.removeListener(_check);
      _editor = scope.editor..addListener(_check);
    }
  }

  void _check() {
    final explorerError = _explorer?.error;
    final editorError = _editor?.error;
    final message = explorerError ?? editorError;
    if (message == null) return;
    // Defer to after the current build/notify cycle.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(message, style: const TextStyle(fontSize: 12.5)),
            backgroundColor: NotelyColors.raised,
            behavior: SnackBarBehavior.floating,
            width: 420,
            duration: const Duration(seconds: 4),
          ),
        );
      _explorer?.clearError();
      _editor?.clearError();
    });
  }

  @override
  void dispose() {
    _explorer?.removeListener(_check);
    _editor?.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
              animation: scope.editor,
              builder: (context, _) {
                final name = _openNoteName(scope.editor);
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

  Future<void> _newFile() async {
    final scope = AppScope.of(context);
    final name = await _promptName('New note', hint: 'Meeting Notes.md');
    if (name == null) return;
    final path = await scope.explorer.createFile(name);
    if (path != null) await scope.editor.open(path);
  }

  Future<void> _newFolder() async {
    final scope = AppScope.of(context);
    final name = await _promptName('New folder', hint: 'Projects');
    if (name == null) return;
    await scope.explorer.createFolder(name);
  }

  Future<String?> _promptName(String title, {required String hint}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: NotelyColors.editor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: NotelyColors.borderStrong),
        ),
        title: Text(
          title,
          style: const TextStyle(fontSize: 15, color: NotelyColors.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
          style: const TextStyle(
            fontSize: 13.5,
            color: NotelyColors.textPrimary,
          ),
          cursorColor: NotelyColors.accent,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: NotelyColors.textFaint),
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
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: NotelyColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text(
              'Create',
              style: TextStyle(color: NotelyColors.accent),
            ),
          ),
        ],
      ),
    ).then((v) => (v == null || v.isEmpty) ? null : v);
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
            padding: const EdgeInsets.fromLTRB(14, 14, 6, 8),
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
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                _iconBtn(Icons.search, 'Search', () => _toggleSearch(explorer)),
                _iconBtn(Icons.note_add_outlined, 'New note', _newFile),
                _iconBtn(
                  Icons.create_new_folder_outlined,
                  'New folder',
                  _newFolder,
                ),
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
          const SizedBox(width: 18),
          AnimatedBuilder(
            animation: scope.editor,
            builder: (context, _) =>
                _item(scope.editor.isDirty ? 'Unsaved' : 'Saved'),
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
