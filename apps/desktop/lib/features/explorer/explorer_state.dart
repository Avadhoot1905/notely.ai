// Explorer (file tree) state, backed by the real Stash filesystem.
//
// Owns the loaded tree, which folders are expanded, the selected file, the folder that new
// items are created in, and the filename filter. Presentation (file_tree.dart) reads this and
// reports user intent back. All disk access goes through [FileSystemService].

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../services/filesystem/file_system_service.dart';
import '../../services/filesystem/fs_node.dart';

/// Outcome of a drag/drop (or programmatic) move.
enum MoveStatus { moved, noop, invalid, collision, error }

class MoveResult {
  const MoveResult(
    this.status, {
    this.oldPath,
    this.newPath,
    this.conflictTarget,
    this.message,
  });

  final MoveStatus status;
  final String? oldPath;
  final String? newPath;
  final String? conflictTarget;
  final String? message;

  static const noop = MoveResult(MoveStatus.noop);
}

class ExplorerController extends ChangeNotifier {
  ExplorerController({FileSystemService? fs})
    : _fs = fs ?? const FileSystemService();

  final FileSystemService _fs;

  String? _rootPath;
  List<FsNode> _roots = const [];
  final Set<String> _expanded = {};
  String? _selectedPath;
  String? _targetDir; // folder new files/folders are created in
  String _query = '';
  String? _error;

  // Inline create/rename state (one at a time).
  String? _creatingInDir;
  bool _creatingIsFolder = false;
  String? _renamingPath;

  String? get rootPath => _rootPath;
  List<FsNode> get roots => _roots;
  String? get selectedPath => _selectedPath;
  String get query => _query;
  bool get isFiltering => _query.trim().isNotEmpty;
  String? get error => _error;

  /// Directory an inline "new item" input is currently shown in (null if none).
  String? get creatingInDir => _creatingInDir;
  bool get creatingIsFolder => _creatingIsFolder;

  /// Path currently being renamed inline (null if none).
  String? get renamingPath => _renamingPath;

  /// The directory new files/folders land in: the explicitly chosen folder, else the root.
  String? get targetDir => _targetDir ?? _rootPath;

  bool isExpanded(String path) => _expanded.contains(path);

  /// Point the explorer at a Stash root and load its contents.
  Future<void> setRoot(String rootPath) async {
    _rootPath = rootPath;
    _targetDir = rootPath;
    _selectedPath = null;
    _expanded.clear();
    await refresh();
  }

  /// Re-read the tree from disk, preserving expansion/selection where still valid.
  Future<void> refresh() async {
    if (_rootPath == null) return;
    try {
      _roots = await _fs.readTree(_rootPath!);
      _error = null;
    } on FileSystemException catch (e) {
      _error = 'Could not read stash: ${e.message}';
      _roots = const [];
    }
    notifyListeners();
  }

  void toggleFolder(String path) {
    if (!_expanded.remove(path)) _expanded.add(path);
    // Selecting a folder makes it the creation target.
    _targetDir = path;
    notifyListeners();
  }

  /// Mark a folder as the active creation target without toggling its expansion.
  void setTargetDir(String path) {
    _targetDir = path;
    notifyListeners();
  }

  void selectFile(String path) {
    _selectedPath = path;
    // New items should land next to the selected file.
    _targetDir = File(path).parent.path;
    notifyListeners();
  }

  void setQuery(String q) {
    _query = q;
    notifyListeners();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// Create a Markdown file in [dirPath] (defaults to [targetDir]/root). Returns its path,
  /// expands to reveal it, and selects it. Returns null and sets [error] on failure.
  Future<String?> createFile(String rawName, {String? dirPath}) async {
    final dir = dirPath ?? targetDir;
    if (dir == null) return null;
    try {
      final path = await _fs.createFile(dir, rawName);
      await refresh();
      _expandAncestors(path);
      _selectedPath = path;
      _error = null;
      notifyListeners();
      return path;
    } on FileSystemException catch (e) {
      _error = e.message;
      notifyListeners();
      return null;
    }
  }

  /// Create a folder in [dirPath] (defaults to [targetDir]/root). Returns its path on success.
  Future<String?> createFolder(String rawName, {String? dirPath}) async {
    final dir = dirPath ?? targetDir;
    if (dir == null) return null;
    try {
      final path = await _fs.createFolder(dir, rawName);
      await refresh();
      _expandAncestors(path);
      _expanded.add(path);
      _targetDir = path;
      _error = null;
      notifyListeners();
      return path;
    } on FileSystemException catch (e) {
      _error = e.message;
      notifyListeners();
      return null;
    }
  }

  void _expandAncestors(String path) {
    if (_rootPath == null) return;
    var dir = File(path).parent;
    // Expand every ancestor folder up to (and including) the root.
    while (dir.path.length >= _rootPath!.length &&
        dir.path.startsWith(_rootPath!)) {
      _expanded.add(dir.path);
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }

  // ── Inline create ─────────────────────────────────────────────────────────

  /// Show an inline "new file/folder" input inside [dir] (defaults to [targetDir]/root).
  void beginCreate({required bool isFolder, String? dir}) {
    final parent = dir ?? targetDir;
    if (parent == null) return;
    _creatingInDir = parent;
    _creatingIsFolder = isFolder;
    _renamingPath = null;
    if (parent != _rootPath) _expanded.add(parent);
    notifyListeners();
  }

  void cancelCreate() {
    if (_creatingInDir == null) return;
    _creatingInDir = null;
    notifyListeners();
  }

  /// Confirm the inline create with [name]. Returns the new path (file) / null.
  Future<String?> confirmCreate(String name) async {
    final dir = _creatingInDir;
    final isFolder = _creatingIsFolder;
    _creatingInDir = null;
    if (dir == null || name.trim().isEmpty) {
      notifyListeners();
      return null;
    }
    return isFolder
        ? createFolder(name, dirPath: dir)
        : createFile(name, dirPath: dir);
  }

  // ── Inline rename ─────────────────────────────────────────────────────────

  void beginRename(String path) {
    _renamingPath = path;
    _creatingInDir = null;
    notifyListeners();
  }

  void cancelRename() {
    if (_renamingPath == null) return;
    _renamingPath = null;
    notifyListeners();
  }

  /// Confirm an inline rename. Returns (oldPath, newPath) on success, else null.
  Future<(String, String)?> confirmRename(String newName) async {
    final path = _renamingPath;
    _renamingPath = null;
    if (path == null || newName.trim().isEmpty) {
      notifyListeners();
      return null;
    }
    try {
      final newPath = await _fs.rename(path, newName);
      await refresh();
      _expandAncestors(newPath);
      if (_selectedPath != null &&
          (p.equals(_selectedPath!, path) ||
              p.isWithin(path, _selectedPath!))) {
        _selectedPath = _remap(_selectedPath!, path, newPath);
      }
      _error = null;
      notifyListeners();
      return (path, newPath);
    } on FileSystemException catch (e) {
      _error = e.message;
      notifyListeners();
      return null;
    }
  }

  // ── Move / delete / reveal ──────────────────────────────────────────────

  /// Whether dropping [source] into [destDir] is structurally valid (no disk access). Used for
  /// live drop-target highlighting.
  bool canDrop(String source, String destDir) {
    if (p.equals(p.dirname(source), destDir)) return false; // same directory
    if (p.equals(source, destDir)) return false; // onto itself
    if (p.isWithin(source, destDir)) return false; // into own descendant
    return true;
  }

  /// Move [source] into [destDir]. Validates structure, detects collisions (returns
  /// [MoveStatus.collision] so the UI can prompt), updates selection, and expands the target.
  Future<MoveResult> move(
    String source, {
    required String destDir,
    bool replace = false,
    String? renameTo,
  }) async {
    if (renameTo == null) {
      // Dropping into the current parent is a no-op.
      if (p.equals(p.dirname(source), destDir)) return MoveResult.noop;
      // Onto itself or into its own descendant is not allowed.
      if (p.equals(source, destDir) || p.isWithin(source, destDir)) {
        return const MoveResult(
          MoveStatus.invalid,
          message: 'Can’t move a folder into itself or its own subfolder.',
        );
      }
    }
    final name = renameTo ?? p.basename(source);
    final target = p.join(destDir, name);
    if (!replace && !p.equals(target, source) && await _fs.exists(target)) {
      return MoveResult(MoveStatus.collision, conflictTarget: target);
    }
    try {
      final newPath = await _fs.move(
        source,
        destDir,
        replace: replace,
        renameTo: renameTo,
      );
      await refresh();
      _expandAncestors(newPath);
      if (_selectedPath != null &&
          (p.equals(_selectedPath!, source) ||
              p.isWithin(source, _selectedPath!))) {
        _selectedPath = _remap(_selectedPath!, source, newPath);
      }
      _targetDir = destDir;
      _error = null;
      notifyListeners();
      return MoveResult(MoveStatus.moved, oldPath: source, newPath: newPath);
    } on FileSystemException catch (e) {
      _error = e.message;
      notifyListeners();
      return MoveResult(MoveStatus.error, message: e.message);
    }
  }

  /// Delete [path] (folders recursively). Returns true on success.
  Future<bool> delete(String path) async {
    try {
      await _fs.delete(path);
      await refresh();
      if (_selectedPath != null &&
          (p.equals(_selectedPath!, path) ||
              p.isWithin(path, _selectedPath!))) {
        _selectedPath = null;
      }
      _expanded.removeWhere((e) => p.equals(e, path) || p.isWithin(path, e));
      _error = null;
      notifyListeners();
      return true;
    } on FileSystemException catch (e) {
      _error = e.message;
      notifyListeners();
      return false;
    }
  }

  Future<void> reveal(String path) async {
    try {
      await _fs.revealInFileManager(path);
    } on Exception catch (e) {
      _error = 'Could not reveal in file manager: $e';
      notifyListeners();
    }
  }

  /// Open [path] with the OS default app (used for image files).
  Future<void> openExternally(String path) async {
    try {
      await _fs.openExternally(path);
    } on Exception catch (e) {
      _error = 'Could not open file: $e';
      notifyListeners();
    }
  }

  /// Copy an image into the stash's attachments folder and refresh the tree. Returns the
  /// imported file's absolute path (for building a Markdown link), or null on failure.
  Future<String?> importImage(String sourcePath) async {
    final root = _rootPath;
    if (root == null) return null;
    try {
      final dest = await _fs.importImage(root, sourcePath);
      await refresh();
      _error = null;
      notifyListeners();
      return dest;
    } on FileSystemException catch (e) {
      _error = e.message;
      notifyListeners();
      return null;
    }
  }

  /// Remap [path] when its prefix [from] becomes [to] (handles the path itself too).
  String _remap(String path, String from, String to) {
    if (p.equals(path, from)) return to;
    return p.join(to, p.relative(path, from: from));
  }
}
