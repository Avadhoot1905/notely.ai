// A node in the real Stash filesystem tree.
//
// The identity of a node is its absolute [path] — this is what the explorer selects and the
// editor opens. Directories carry their [children]; files do not. Markdown notes and embedded
// images are surfaced by the [FileSystemService]; other file types stay hidden.

import 'package:path/path.dart' as p;

class FsNode {
  FsNode({
    required this.path,
    required this.isDirectory,
    this.children = const [],
  });

  /// Absolute path on disk. Stable identity for selection/open.
  final String path;
  final bool isDirectory;

  /// Populated for directories only.
  final List<FsNode> children;

  /// Image extensions Notely recognises for embedding in notes.
  static const imageExtensions = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'svg',
  };

  String get name => p.basename(path);
  bool get isMarkdown => !isDirectory && name.toLowerCase().endsWith('.md');
  bool get isImage {
    if (isDirectory) return false;
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return imageExtensions.contains(ext);
  }
}
