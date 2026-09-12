// The main three-region desktop layout: title bar, (sidebar | editor | transcript), status bar.
//
// The transcript region does NOT exist in the normal state; it slides in for any active
// session (listening / paused / reviewing) and the editor reflows to make room. Narrow windows
// shrink the transcript toward its minimum and keep the editor usable. All color comes from
// `context.tokens` so the whole shell re-themes in light/dark with no hard-coded values.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../ask/ask_button.dart';
import '../ask/ask_panel.dart';
import '../editor/editor_state.dart';
import '../editor/markdown_editor.dart';
import '../explorer/explorer_state.dart';
import '../explorer/file_tree.dart';
import '../listening/listening_button.dart';
import '../listening/transcript_panel.dart';
import '../stash/stash_switcher.dart';

class WorkspaceShell extends StatelessWidget {
  const WorkspaceShell({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final t = context.tokens;
    return _ErrorListener(
      child: _TitleSync(
        child: Scaffold(
          backgroundColor: t.background,
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
                    _VerticalDivider(t),
                    Expanded(
                      child: AnimatedBuilder(
                        animation: Listenable.merge([
                          scope.listening,
                          scope.ask,
                        ]),
                        builder: (context, _) {
                          // Ask takes the right dock; otherwise the live transcript uses it.
                          final askOpen = scope.ask.isOpen;
                          final showTranscript = scope.listening.showTranscript;
                          final showRight = askOpen || showTranscript;
                          return LayoutBuilder(
                            builder: (context, constraints) {
                              // Shrink the right panel toward its minimum on narrow windows so
                              // the editor stays usable.
                              final available = constraints.maxWidth;
                              final panelW = askOpen
                                  ? (available < 820
                                        ? NotelyDims.askMinWidth
                                        : NotelyDims.askWidth)
                                  : (available < 760
                                        ? NotelyDims.transcriptMinWidth
                                        : NotelyDims.transcriptWidth);
                              return Row(
                                children: [
                                  const Expanded(child: MarkdownEditor()),
                                  ClipRect(
                                    child: AnimatedAlign(
                                      alignment: Alignment.centerLeft,
                                      duration: NotelyDims.panelAnim,
                                      curve: NotelyMotion.curve,
                                      widthFactor: showRight ? 1.0 : 0.0,
                                      child: SizedBox(
                                        width: panelW,
                                        child: showRight
                                            ? (askOpen
                                                  ? const AskPanel()
                                                  : const TranscriptPanel())
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
    final message = _explorer?.error ?? _editor?.error;
    if (message == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final t = context.tokens;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              message,
              style: TextStyle(fontSize: 12.5, color: t.textPrimary),
            ),
            backgroundColor: t.raised,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(NotelyDims.radius),
              side: BorderSide(color: t.danger.withValues(alpha: 0.6)),
            ),
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
// Title sync — keep the open note's filename == its first line (H1 title).
// ─────────────────────────────────────────────────────────────────────────────
class _TitleSync extends StatefulWidget {
  const _TitleSync({required this.child});
  final Widget child;

  @override
  State<_TitleSync> createState() => _TitleSyncState();
}

class _TitleSyncState extends State<_TitleSync> {
  static const _debounce = Duration(milliseconds: 600);
  EditorController? _editor;
  ExplorerController? _explorer;
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.of(context);
    _explorer = scope.explorer;
    if (_editor != scope.editor) {
      _editor?.removeListener(_onEdit);
      _editor = scope.editor..addListener(_onEdit);
    }
  }

  void _onEdit() {
    _timer?.cancel();
    _timer = Timer(_debounce, _sync);
  }

  Future<void> _sync() async {
    final editor = _editor;
    final explorer = _explorer;
    if (editor == null || explorer == null) return;
    if (!editor.hasOpenNote || editor.isLoading) return;
    // Only react to genuine user edits (open() leaves the note clean).
    if (!editor.isDirty) return;

    final title = ExplorerController.titleToFileName(editor.firstLine);
    if (title == null) return;
    final current = p.basenameWithoutExtension(editor.openPath!);
    if (title == current) return;

    // Flush to the current path first, then rename the file to match the title.
    await editor.saveNow();
    final res = await explorer.renameForTitle(editor.openPath!, title);
    if (res != null && mounted) editor.handlePathMoved(res.$1, res.$2);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _editor?.removeListener(_onEdit);
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
    final t = context.tokens;
    return Container(
      height: NotelyDims.titleBarHeight,
      decoration: BoxDecoration(
        color: t.background,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          // Identity mark.
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: t.accent,
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
          const SizedBox(width: 12),
          AnimatedBuilder(
            animation: scope.stash,
            builder: (context, _) => Text(
              scope.stash.name ?? 'Notely',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: t.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          _Dot(t),
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
                    color: name == null ? t.textFaint : t.textSecondary,
                  ),
                );
              },
            ),
          ),
          const AskButton(),
          const SizedBox(width: 8),
          const _ThemeToggle(),
          const SizedBox(width: 2),
          _ChromeIcon(icon: Icons.more_horiz, tip: 'Menu', onTap: () {}),
        ],
      ),
    );
  }
}

/// Compact theme control: cycles Dark → Light → System with a reflective icon.
class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context) {
    final theme = AppScope.of(context).theme;
    return AnimatedBuilder(
      animation: theme,
      builder: (context, _) {
        final (IconData icon, String label) = switch (theme.mode) {
          ThemeMode.dark => (Icons.dark_mode_outlined, 'Theme: Dark'),
          ThemeMode.light => (Icons.light_mode_outlined, 'Theme: Light'),
          ThemeMode.system => (Icons.brightness_auto_outlined, 'Theme: System'),
        };
        return _ChromeIcon(
          icon: icon,
          tip: '$label — click to change',
          onTap: theme.cycle,
        );
      },
    );
  }
}

class _ChromeIcon extends StatefulWidget {
  const _ChromeIcon({
    required this.icon,
    required this.tip,
    required this.onTap,
  });
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  State<_ChromeIcon> createState() => _ChromeIconState();
}

class _ChromeIconState extends State<_ChromeIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: widget.tip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: NotelyMotion.fast,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _hover ? t.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: _hover ? t.textSecondary : t.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.t);
  final NotelyTokens t;
  @override
  Widget build(BuildContext context) => Container(
    width: 3,
    height: 3,
    decoration: BoxDecoration(color: t.textFaint, shape: BoxShape.circle),
  );
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

  void _newFile() => AppScope.of(context).explorer.beginCreate(isFolder: false);

  void _newFolder() =>
      AppScope.of(context).explorer.beginCreate(isFolder: true);

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final explorer = scope.explorer;
    final t = context.tokens;
    return Container(
      color: t.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Explorer header + actions (the stash identity now lives in the bottom switcher).
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 6, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'EXPLORER',
                    style: NotelyType.sectionLabel.copyWith(color: t.textFaint),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _iconBtn(
                  t,
                  Icons.search,
                  'Search',
                  () => _toggleSearch(explorer),
                ),
                _iconBtn(t, Icons.note_add_outlined, 'New note', _newFile),
                _iconBtn(
                  t,
                  Icons.create_new_folder_outlined,
                  'New folder',
                  _newFolder,
                ),
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
                style: TextStyle(fontSize: 12.5, color: t.textPrimary),
                cursorColor: t.accent,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Filter notes…',
                  hintStyle: TextStyle(color: t.textFaint, fontSize: 12.5),
                  filled: true,
                  fillColor: t.background,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  prefixIcon: Icon(Icons.search, size: 14, color: t.textFaint),
                  prefixIconConstraints: const BoxConstraints(minWidth: 30),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(NotelyDims.radius),
                    borderSide: BorderSide(color: t.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(NotelyDims.radius),
                    borderSide: BorderSide(color: t.accent, width: 1.5),
                  ),
                ),
              ),
            ),
          Divider(height: 1, color: t.border),
          const Expanded(child: FileTree()),
          Divider(height: 1, color: t.border),
          const StashSwitcher(),
        ],
      ),
    );
  }

  Widget _iconBtn(
    NotelyTokens t,
    IconData icon,
    String tip,
    VoidCallback onTap,
  ) {
    return _SidebarIcon(icon: icon, tip: tip, onTap: onTap);
  }
}

class _SidebarIcon extends StatefulWidget {
  const _SidebarIcon({
    required this.icon,
    required this.tip,
    required this.onTap,
  });
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  State<_SidebarIcon> createState() => _SidebarIconState();
}

class _SidebarIconState extends State<_SidebarIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: widget.tip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: NotelyMotion.fast,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _hover ? t.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
            ),
            child: Icon(
              widget.icon,
              size: 15,
              color: _hover ? t.textSecondary : t.textFaint,
            ),
          ),
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
    final t = context.tokens;
    return Container(
      height: NotelyDims.statusBarHeight,
      decoration: BoxDecoration(
        color: t.background,
        border: Border(top: BorderSide(color: t.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: scope.stash,
            builder: (context, _) => _item(t, scope.stash.name ?? '—'),
          ),
          const SizedBox(width: 14),
          AnimatedBuilder(
            animation: scope.editor,
            builder: (context, _) {
              if (!scope.editor.hasOpenNote) return const SizedBox.shrink();
              final dirty = scope.editor.isDirty;
              return Row(
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: dirty ? t.warning : t.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  _item(t, dirty ? 'Unsaved' : 'Saved'),
                ],
              );
            },
          ),
          const Spacer(),
          _item(t, 'Markdown'),
          const SizedBox(width: 14),
          _Dot(t),
          const SizedBox(width: 14),
          _item(t, 'UTF-8'),
          const SizedBox(width: 14),
          _Dot(t),
          const SizedBox(width: 14),
          AnimatedBuilder(
            animation: scope.editor,
            builder: (context, _) => Text(
              scope.editor.hasOpenNote
                  ? 'Ln ${scope.editor.line}, Col ${scope.editor.col}'
                  : 'Ln —, Col —',
              style: NotelyType.statusMono.copyWith(color: t.textFaint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(NotelyTokens t, String text) =>
      Text(text, style: TextStyle(fontSize: 11, color: t.textFaint));
}

class _VerticalDivider extends StatelessWidget {
  const _VerticalDivider(this.t);
  final NotelyTokens t;

  @override
  Widget build(BuildContext context) => Container(width: 1, color: t.border);
}
