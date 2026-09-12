// The explorer file tree, backed by the real Stash filesystem.
//
// Responsibilities here are UI-only: flatten the loaded [FsNode] tree into compact rows, host
// the right-click context menu, inline create/rename inputs, and internal drag-and-drop. Every
// mutating action delegates to [ExplorerController] (which delegates to FileSystemService), and
// open-file path changes are forwarded to the [EditorController]. No filesystem calls live in
// this widget.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../services/filesystem/fs_node.dart';
import '../editor/editor_state.dart';
import 'explorer_context_menu.dart';
import 'explorer_state.dart';
import 'file_tree_item.dart';
import 'inline_edit_row.dart';

class FileTree extends StatefulWidget {
  const FileTree({super.key});

  @override
  State<FileTree> createState() => _FileTreeState();
}

class _FileTreeState extends State<FileTree> {
  final FocusNode _focus = FocusNode(debugLabel: 'explorer-tree');
  bool _overFolder =
      false; // suppresses root highlight while over a folder target

  ExplorerController get _explorer => AppScope.of(context).explorer;
  EditorController get _editor => AppScope.of(context).editor;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  void _openFile(FsNode node) {
    _explorer.selectFile(node.path);
    _focus.requestFocus();
    // Images can't be edited as text — open them in the OS default viewer instead.
    if (node.isImage) {
      _explorer.openExternally(node.path);
    } else {
      _editor.open(node.path);
    }
  }

  Future<void> _runAction(ExplorerAction action, FsNode? node) async {
    final explorer = _explorer;
    final rootPath = explorer.rootPath;
    switch (action) {
      case ExplorerAction.open:
        if (node != null) _openFile(node);
      case ExplorerAction.newFile:
        explorer.beginCreate(isFolder: false, dir: _dirOf(node, rootPath));
      case ExplorerAction.newFolder:
        explorer.beginCreate(isFolder: true, dir: _dirOf(node, rootPath));
      case ExplorerAction.rename:
        if (node != null) explorer.beginRename(node.path);
      case ExplorerAction.delete:
        if (node != null) await _confirmDelete(node);
      case ExplorerAction.copyPath:
        if (node != null) {
          await Clipboard.setData(ClipboardData(text: node.path));
          _snack('Path copied');
        }
      case ExplorerAction.reveal:
        if (node != null) await explorer.reveal(node.path);
      case ExplorerAction.refresh:
        await explorer.refresh();
    }
  }

  /// Directory an action applies to: the folder itself, a file's parent, or the root.
  String? _dirOf(FsNode? node, String? rootPath) {
    if (node == null) return rootPath;
    return node.isDirectory ? node.path : p.dirname(node.path);
  }

  Future<void> _onContext(
    Offset pos,
    FsNode? node,
    ExplorerTargetKind kind,
  ) async {
    _focus.requestFocus();
    final action = await showExplorerContextMenu(
      context: context,
      globalPosition: pos,
      kind: kind,
    );
    if (action == null || !mounted) return;
    await _runAction(action, node);
  }

  Future<void> _confirmDelete(FsNode node) async {
    final editor = _editor;
    final open = editor.openPath;
    final affectsOpen =
        open != null &&
        (p.equals(open, node.path) || p.isWithin(node.path, open));
    final dirtyWarning = affectsOpen && editor.isDirty;
    final nonEmptyFolder = node.isDirectory && node.children.isNotEmpty;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final t = context.tokens;
        return AlertDialog(
          backgroundColor: t.editor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NotelyDims.radiusLarge),
            side: BorderSide(color: t.borderStrong),
          ),
          title: Text(
            'Delete "${node.name}"?',
            style: NotelyType.dialogTitle.copyWith(
              fontSize: 15,
              color: t.textPrimary,
            ),
          ),
          content: Text(
            [
              if (nonEmptyFolder)
                'This folder and everything inside it will be deleted.',
              if (dirtyWarning) 'It has unsaved changes that will be lost.',
              'This cannot be undone.',
            ].join('\n'),
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: t.textSecondary,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Delete', style: TextStyle(color: t.danger)),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    final ok = await _explorer.delete(node.path);
    if (ok) _editor.handlePathDeleted(node.path);
  }

  // ── Drag & drop ─────────────────────────────────────────────────────────

  Future<void> _handleDrop(String source, String destDir) async {
    final res = await _explorer.move(source, destDir: destDir);
    await _applyMoveResult(res, source, destDir);
  }

  Future<void> _applyMoveResult(
    MoveResult res,
    String source,
    String destDir,
  ) async {
    switch (res.status) {
      case MoveStatus.moved:
        _editor.handlePathMoved(res.oldPath!, res.newPath!);
      case MoveStatus.noop:
        break;
      case MoveStatus.invalid:
        _snack(res.message ?? 'That move isn’t allowed.');
      case MoveStatus.error:
        break; // explorer.error → global error toast
      case MoveStatus.collision:
        await _resolveCollision(source, destDir, res.conflictTarget!);
    }
  }

  Future<void> _resolveCollision(
    String source,
    String destDir,
    String target,
  ) async {
    final name = p.basename(target);
    final choice = await showDialog<String>(
      context: context,
      builder: (context) {
        final t = context.tokens;
        return AlertDialog(
          backgroundColor: t.editor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NotelyDims.radiusLarge),
            side: BorderSide(color: t.borderStrong),
          ),
          title: Text(
            'Name already exists',
            style: NotelyType.dialogTitle.copyWith(
              fontSize: 15,
              color: t.textPrimary,
            ),
          ),
          content: Text(
            'An item named "$name" already exists here.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: t.textSecondary,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop('cancel'),
              child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('rename'),
              child: Text('Rename', style: TextStyle(color: t.textPrimary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('replace'),
              child: Text('Replace', style: TextStyle(color: t.danger)),
            ),
          ],
        );
      },
    );
    if (!mounted || choice == null || choice == 'cancel') return;

    if (choice == 'replace') {
      final res = await _explorer.move(source, destDir: destDir, replace: true);
      await _applyMoveResult(res, source, destDir);
    } else if (choice == 'rename') {
      final newName = await _promptName(p.basename(source));
      if (newName == null || !mounted) return;
      final res = await _explorer.move(
        source,
        destDir: destDir,
        renameTo: newName,
      );
      await _applyMoveResult(res, source, destDir);
    }
  }

  Future<String?> _promptName(String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) {
        final t = context.tokens;
        return AlertDialog(
          backgroundColor: t.editor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(NotelyDims.radiusLarge),
            side: BorderSide(color: t.borderStrong),
          ),
          title: Text(
            'New name',
            style: NotelyType.dialogTitle.copyWith(
              fontSize: 15,
              color: t.textPrimary,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
            style: TextStyle(fontSize: 13.5, color: t.textPrimary),
            cursorColor: t.accent,
            decoration: InputDecoration(
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(NotelyDims.radius),
                borderSide: BorderSide(color: t.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(NotelyDims.radius),
                borderSide: BorderSide(color: t.accent),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: TextStyle(color: t.textSecondary)),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: Text('Move', style: TextStyle(color: t.accent)),
            ),
          ],
        );
      },
    ).then((v) => (v == null || v.isEmpty) ? null : v);
  }

  void _snack(String message) {
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
            side: BorderSide(color: t.border),
          ),
          width: 360,
          duration: const Duration(seconds: 3),
        ),
      );
  }

  // ── Keyboard ──────────────────────────────────────────────────────────────

  void _renameSelected() {
    if (!_focus.hasPrimaryFocus) return;
    final sel = _explorer.selectedPath;
    if (sel != null) _explorer.beginRename(sel);
  }

  Future<void> _deleteSelected() async {
    if (!_focus.hasPrimaryFocus) return;
    final sel = _explorer.selectedPath;
    if (sel == null) return;
    final node = _findNode(_explorer.roots, sel);
    if (node != null) await _confirmDelete(node);
  }

  FsNode? _findNode(List<FsNode> nodes, String path) {
    for (final n in nodes) {
      if (p.equals(n.path, path)) return n;
      if (n.isDirectory) {
        final found = _findNode(n.children, path);
        if (found != null) return found;
      }
    }
    return null;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final explorer = scope.explorer;

    return Focus(
      focusNode: _focus,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f2): _renameSelected,
          const SingleActivator(LogicalKeyboardKey.delete): _deleteSelected,
        },
        child: AnimatedBuilder(
          animation: explorer,
          builder: (context, _) => _buildTree(explorer, scope),
        ),
      ),
    );
  }

  Widget _buildTree(ExplorerController explorer, AppScope scope) {
    final t = context.tokens;
    final rows = _buildRows(explorer, scope);
    final rootPath = explorer.rootPath;

    final Widget body = rows.isEmpty
        ? Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              explorer.query.trim().isEmpty
                  ? 'This stash is empty.\nRight-click to create a note or folder.'
                  : 'No notes match your search.',
              style: TextStyle(fontSize: 12, height: 1.5, color: t.textFaint),
            ),
          )
        : ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: rows,
          );

    // Root drop target + empty-space context menu wrap the whole list.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (d) =>
          _onContext(d.globalPosition, null, ExplorerTargetKind.empty),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (d) =>
            rootPath != null && explorer.canDrop(d.data, rootPath),
        onAcceptWithDetails: (d) => _handleDrop(d.data, rootPath!),
        builder: (context, candidate, rejected) {
          final highlight = candidate.isNotEmpty && !_overFolder;
          return AnimatedContainer(
            duration: NotelyMotion.fast,
            decoration: BoxDecoration(
              color: highlight ? t.selection : Colors.transparent,
              border: Border.all(
                color: highlight ? t.accent : Colors.transparent,
                width: 1,
              ),
            ),
            child: SizedBox.expand(child: body),
          );
        },
      ),
    );
  }

  List<Widget> _buildRows(ExplorerController explorer, AppScope scope) {
    final rows = <Widget>[];
    final query = explorer.query.trim().toLowerCase();
    final rootPath = explorer.rootPath;
    final filtering = query.isNotEmpty;

    // Root-level inline create input.
    if (!filtering &&
        explorer.creatingInDir != null &&
        rootPath != null &&
        p.equals(explorer.creatingInDir!, rootPath)) {
      rows.add(_inlineCreate(explorer, 0));
    }

    void walk(List<FsNode> nodes, int depth) {
      for (final node in nodes) {
        if (node.isDirectory) {
          if (filtering) {
            walk(node.children, depth);
            continue;
          }
          if (explorer.renamingPath == node.path) {
            rows.add(_inlineRename(explorer, node, depth));
          } else {
            rows.add(_folderRow(explorer, scope, node, depth));
          }
          if (explorer.isExpanded(node.path)) {
            if (explorer.creatingInDir != null &&
                p.equals(explorer.creatingInDir!, node.path)) {
              rows.add(_inlineCreate(explorer, depth + 1));
            }
            walk(node.children, depth + 1);
          }
        } else {
          if (filtering && !node.name.toLowerCase().contains(query)) continue;
          final depthForFile = filtering ? 0 : depth;
          if (!filtering && explorer.renamingPath == node.path) {
            rows.add(_inlineRename(explorer, node, depthForFile));
          } else {
            rows.add(_fileRow(explorer, scope, node, depthForFile));
          }
        }
      }
    }

    walk(explorer.roots, 0);
    return rows;
  }

  Widget _inlineCreate(ExplorerController explorer, int depth) {
    return InlineEditRow(
      key: const ValueKey('inline-create'),
      depth: depth,
      isFolder: explorer.creatingIsFolder,
      onSubmit: (name) async {
        final isFolder = explorer.creatingIsFolder;
        final path = await explorer.confirmCreate(name);
        if (path != null && !isFolder) await _editor.open(path);
      },
      onCancel: explorer.cancelCreate,
    );
  }

  Widget _inlineRename(ExplorerController explorer, FsNode node, int depth) {
    return InlineEditRow(
      key: ValueKey('inline-rename-${node.path}'),
      depth: depth,
      isFolder: node.isDirectory,
      initialText: node.name,
      onSubmit: (name) async {
        final res = await explorer.confirmRename(name);
        if (res != null) _editor.handlePathMoved(res.$1, res.$2);
      },
      onCancel: explorer.cancelRename,
    );
  }

  Widget _folderRow(
    ExplorerController explorer,
    AppScope scope,
    FsNode node,
    int depth,
  ) {
    final target = DragTarget<String>(
      onWillAcceptWithDetails: (d) => explorer.canDrop(d.data, node.path),
      onMove: (_) {
        if (!_overFolder) setState(() => _overFolder = true);
      },
      onLeave: (_) {
        if (_overFolder) setState(() => _overFolder = false);
      },
      onAcceptWithDetails: (d) {
        setState(() => _overFolder = false);
        _handleDrop(d.data, node.path);
      },
      builder: (context, candidate, rejected) => FileTreeItem(
        name: node.name,
        depth: depth,
        isFolder: true,
        isExpanded: explorer.isExpanded(node.path),
        isDropTarget: candidate.isNotEmpty,
        onTap: () {
          explorer.toggleFolder(node.path);
          _focus.requestFocus();
        },
        onSecondaryTapDown: (pos) =>
            _onContext(pos, node, ExplorerTargetKind.folder),
      ),
    );
    return _draggable(node, depth, isFolder: true, child: target);
  }

  Widget _fileRow(
    ExplorerController explorer,
    AppScope scope,
    FsNode node,
    int depth,
  ) {
    final item = FileTreeItem(
      name: node.name,
      depth: depth,
      isFolder: false,
      isImage: node.isImage,
      isSelected: explorer.selectedPath == node.path,
      onTap: () => _openFile(node),
      onSecondaryTapDown: (pos) =>
          _onContext(pos, node, ExplorerTargetKind.file),
    );
    return _draggable(node, depth, isFolder: false, child: item);
  }

  Widget _draggable(
    FsNode node,
    int depth, {
    required bool isFolder,
    required Widget child,
  }) {
    return Draggable<String>(
      data: node.path,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragEnd: (_) {
        if (_overFolder) setState(() => _overFolder = false);
      },
      feedback: _dragFeedback(node, isFolder),
      childWhenDragging: Opacity(
        opacity: 0.4,
        child: IgnorePointer(
          child: FileTreeItem(
            name: node.name,
            depth: depth,
            isFolder: isFolder,
            onTap: () {},
          ),
        ),
      ),
      child: child,
    );
  }

  Widget _dragFeedback(FsNode node, bool isFolder) {
    final t = context.tokens;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: t.raised,
          borderRadius: BorderRadius.circular(NotelyDims.radius),
          border: Border.all(color: t.accent),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isFolder ? Icons.folder_rounded : Icons.article_outlined,
              size: 13,
              color: t.textSecondary,
            ),
            const SizedBox(width: 7),
            Text(
              node.name,
              style: NotelyType.row.copyWith(color: t.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
