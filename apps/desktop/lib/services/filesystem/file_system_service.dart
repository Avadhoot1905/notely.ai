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
      } else if (entity is File) {
        final node = FsNode(path: entity.path, isDirectory: false);
        // Surface notes and embedded images; hide everything else.
        if (node.isMarkdown || node.isImage) files.add(node);
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

  /// Rename the file/folder at [path] to [newName] within the same directory. Returns the new
  /// absolute path. A `.md` extension is preserved/added for files. Throws on collision.
  Future<String> rename(String path, String newName) async {
    final isDir = await Directory(path).exists();
    final name = isDir ? newName.trim() : _ensureMarkdown(newName);
    if (name.isEmpty || (isDir && newName.trim().isEmpty)) {
      throw FileSystemException('Name cannot be empty', path);
    }
    final dest = p.join(p.dirname(path), name);
    if (p.equals(dest, path)) return path; // unchanged
    // A case-only rename ("notes.md" → "Notes.md") targets the *same* entry on a
    // case-insensitive filesystem (macOS/APFS default, Windows/NTFS), so exists(dest) would be
    // true and falsely report a collision. Detect it and let the OS rename in place instead.
    final caseOnly = _isCaseOnlyRename(path, dest);
    if (!caseOnly && await exists(dest)) {
      throw FileSystemException(
        'A ${isDir ? 'folder' : 'file'} named "$name" already exists',
        dest,
      );
    }
    final entity = isDir ? Directory(path) : File(path);
    final renamed = await _renameEntity(entity, dest, caseOnly: caseOnly);
    return renamed.path;
  }

  /// Move [source] into directory [destDir]. With [renameTo] the moved item is also renamed.
  /// With [replace] an existing item at the destination is deleted first. Returns the new path.
  Future<String> move(
    String source,
    String destDir, {
    bool replace = false,
    String? renameTo,
  }) async {
    final isDir = await Directory(source).exists();
    final name = renameTo != null
        ? (isDir ? renameTo.trim() : _ensureMarkdown(renameTo))
        : p.basename(source);
    final dest = p.join(destDir, name);
    // See rename(): a case-only rename targets the same entry on case-insensitive filesystems,
    // so it must not be treated as a collision (and must not delete "the existing item").
    final caseOnly = _isCaseOnlyRename(source, dest);
    if (!caseOnly && !p.equals(dest, source) && await exists(dest)) {
      if (!replace) {
        throw FileSystemException(
          'An item named "$name" already exists here',
          dest,
        );
      }
      await delete(dest);
    }
    final entity = isDir ? Directory(source) : File(source);
    final moved = await _renameEntity(entity, dest, caseOnly: caseOnly);
    return moved.path;
  }

  /// Delete a file, or a folder (recursively — callers confirm destructive deletes).
  Future<void> delete(String path) async {
    final dir = Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      return;
    }
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  /// Reveal [path] in the platform file manager (Finder / File Explorer / default handler),
  /// highlighting the item where the OS supports it.
  Future<void> revealInFileManager(String path) async {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      // Explorer requires the flag and path as a SINGLE token ("/select,C:\dir\file"); passing
      // them as two arguments splits on the space and fails to highlight. Explorer also returns
      // a non-zero exit code even on success, so we don't inspect it here.
      await Process.run('explorer', ['/select,${p.normalize(path)}']);
    } else if (Platform.isLinux) {
      await _revealOnLinux(path);
    } else {
      throw const FileSystemException(
        'Reveal is not supported on this platform',
      );
    }
  }

  /// Reveal [path] on Linux without assuming a specific desktop environment or file manager.
  ///
  /// The freedesktop `org.freedesktop.FileManager1` D-Bus interface is the portable, DE-agnostic
  /// way to *highlight* a file (Nautilus/GNOME, Dolphin/KDE, Nemo, … all implement it). We try it
  /// first via `gdbus`, and fall back to opening the containing folder with `xdg-open` when the
  /// interface, gdbus, or a session bus isn't available (e.g. a minimal/headless environment).
  Future<void> _revealOnLinux(String path) async {
    final isDir = await Directory(path).exists();
    if (!isDir) {
      final uri = Uri.file(path).toString();
      try {
        final result = await Process.run('gdbus', [
          'call',
          '--session',
          '--dest',
          'org.freedesktop.FileManager1',
          '--object-path',
          '/org/freedesktop/FileManager1',
          '--method',
          'org.freedesktop.FileManager1.ShowItems',
          '[$_dq$uri$_dq]',
          '',
        ]);
        if (result.exitCode == 0) return;
      } catch (_) {
        // gdbus missing or no session bus — fall through to xdg-open.
      }
    }
    // Fallback: open the folder itself (can't highlight the specific item).
    final target = isDir ? path : p.dirname(path);
    await Process.run('xdg-open', [target]);
  }

  static const _dq = '"';

  /// Open [path] with the platform's default application (e.g. an image in Preview). Unlike
  /// [revealInFileManager], this opens the file itself rather than highlighting it.
  Future<void> openExternally(String path) async {
    if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [path]);
    } else {
      throw const FileSystemException('Open is not supported on this platform');
    }
  }

  /// Default folder (relative to the stash root) that embedded images are copied into.
  static const attachmentsDir = 'attachments';

  /// Copy an image at [sourcePath] into `<stashRoot>/attachments/`, keeping the original name
  /// (de-duplicated on collision). Returns the copied file's absolute path so callers can build
  /// a relative Markdown link. The stash filesystem stays the source of truth — the image is a
  /// real file living beside the notes that reference it.
  Future<String> importImage(String stashRoot, String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('Image not found', sourcePath);
    }
    final dir = Directory(p.join(stashRoot, attachmentsDir));
    if (!await dir.exists()) await dir.create(recursive: true);

    final dest = await _uniquePath(dir.path, p.basename(sourcePath));
    await source.copy(dest);
    return dest;
  }

  /// A path inside [dirPath] for [fileName] that doesn't collide (adds " 1", " 2", … before
  /// the extension as needed).
  Future<String> _uniquePath(String dirPath, String fileName) async {
    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    var candidate = p.join(dirPath, fileName);
    var i = 1;
    while (await File(candidate).exists() ||
        await Directory(candidate).exists()) {
      candidate = p.join(dirPath, '$base $i$ext');
      i++;
    }
    return candidate;
  }

  /// True when [dest] differs from [source] only by letter case within the same parent — i.e.
  /// the same on-disk entry on a case-insensitive filesystem. The paths must be different
  /// case-sensitively (a true no-op is handled by the caller) but equal case-insensitively.
  static bool _isCaseOnlyRename(String source, String dest) {
    if (p.equals(source, dest)) return false; // identical → not a case change
    return p.equals(
      source.toLowerCase(),
      dest.toLowerCase(),
    ); // same path, different case
  }

  /// Rename [entity] to [dest]. A case-only rename on a case-insensitive filesystem can fail or
  /// no-op on some OSes when renaming directly, so it is performed via a unique temporary name
  /// first. Case-sensitive filesystems (typical Linux) are unaffected and take the direct path.
  Future<FileSystemEntity> _renameEntity(
    FileSystemEntity entity,
    String dest, {
    required bool caseOnly,
  }) async {
    if (!caseOnly) return entity.rename(dest);
    final parent = p.dirname(dest);
    var temp = p.join(parent, '.${p.basename(dest)}.notely-tmp');
    var i = 0;
    while (await exists(temp)) {
      temp = p.join(parent, '.${p.basename(dest)}.notely-tmp$i');
      i++;
    }
    final viaTemp = await entity.rename(temp);
    return viaTemp.rename(dest);
  }

  String _ensureMarkdown(String rawName) {
    final name = rawName.trim();
    if (name.isEmpty) return 'Untitled.md';
    return name.toLowerCase().endsWith('.md') ? name : '$name.md';
  }
}
