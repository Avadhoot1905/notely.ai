// Explorer (file tree) state, backed by the real Stash filesystem.
//
// Owns the loaded tree, which folders are expanded, the selected file, the folder that new
// items are created in, and the filename filter. Presentation (file_tree.dart) reads this and
// reports user intent back. All disk access goes through [FileSystemService].

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../services/filesystem/file_system_service.dart';
import '../../services/filesystem/fs_node.dart';

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

  String? get rootPath => _rootPath;
  List<FsNode> get roots => _roots;
  String? get selectedPath => _selectedPath;
  String get query => _query;
  bool get isFiltering => _query.trim().isNotEmpty;
  String? get error => _error;

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
}
