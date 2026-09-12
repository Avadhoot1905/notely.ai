// Real filesystem access for a Stash.
//
// This is the single place the app reads/writes the user's Markdown files. Widgets never touch
// dart:io directly — they go through an [ExplorerController]/[EditorController] which use this.
// Operations throw [FileSystemException]; callers surface those as non-intrusive UI errors.
//
// Later, a Rust-backed implementation could replace this behind the same method surface if we
// want indexing/watching in the engine — but local-first means the filesystem stays
// authoritative, so a thin Dart implementation is the right default.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'fs_node.dart';

class FileSystemService {
  const FileSystemService();

  /// Read the Stash tree rooted at [rootPath]. Directories are listed first, then Markdown
  /// files, each alphabetically. Hidden entries (dotfiles) and non-Markdown files are skipped
  /// to keep the explorer focused on notes.
  Future<List<FsNode>> readTree(String rootPath) async {
    return _readDir(rootPath);
  }

  Future<List<FsNode>> _readDir(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];

    final dirs = <FsNode>[];
    final files = <FsNode>[];

    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue; // skip dotfiles/.DS_Store/.git
      if (entity is Directory) {
        dirs.add(
          FsNode(
            path: entity.path,
            isDirectory: true,
            children: await _readDir(entity.path),
          ),
        );
      } else if (entity is File && name.toLowerCase().endsWith('.md')) {
        files.add(FsNode(path: entity.path, isDirectory: false));
      }
    }

    int byName(FsNode a, FsNode b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    dirs.sort(byName);
    files.sort(byName);
    return [...dirs, ...files];
  }

  Future<String> readFile(String path) => File(path).readAsString();

  Future<void> writeFile(String path, String content) =>
      File(path).writeAsString(content);

  /// Create a new Markdown file named [rawName] inside [dirPath]. A `.md` extension is added
  /// only if the user didn't already supply one. Returns the created file's absolute path.
  /// Throws if a file with that name already exists.
  Future<String> createFile(String dirPath, String rawName) async {
    final name = _ensureMarkdown(rawName);
    final path = p.join(dirPath, name);
    final file = File(path);
    if (await file.exists()) {
      throw FileSystemException('A file named "$name" already exists', path);
    }
    await file.create(recursive: true);
    await file.writeAsString('# ${p.basenameWithoutExtension(name)}\n\n');
    return path;
  }

  /// Create a new folder named [rawName] inside [dirPath]. Returns its absolute path.
  Future<String> createFolder(String dirPath, String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty) {
      throw const FileSystemException('Folder name cannot be empty');
    }
    final path = p.join(dirPath, name);
    final dir = Directory(path);
    if (await dir.exists()) {
      throw FileSystemException('A folder named "$name" already exists', path);
    }
    await dir.create(recursive: false);
    return path;
  }

  Future<bool> exists(String path) async =>
      await File(path).exists() || await Directory(path).exists();

  String _ensureMarkdown(String rawName) {
    final name = rawName.trim();
    if (name.isEmpty) return 'Untitled.md';
    return name.toLowerCase().endsWith('.md') ? name : '$name.md';
  }
}
