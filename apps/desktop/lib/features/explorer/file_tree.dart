// The explorer file tree, backed by the real Stash filesystem.
//
// Flattens the loaded [FsNode] tree into visible rows based on which folders are expanded, and
// renders them as compact [FileTreeItem]s. A filename filter flattens to matching Markdown
// files. Node identity is the absolute path.

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../services/filesystem/fs_node.dart';
import 'file_tree_item.dart';

class FileTree extends StatelessWidget {
  const FileTree({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final explorer = scope.explorer;

    return AnimatedBuilder(
      animation: explorer,
      builder: (context, _) {
        final rows = <Widget>[];
        final query = explorer.query.trim().toLowerCase();

        void walk(List<FsNode> nodes, int depth) {
          for (final node in nodes) {
            if (node.isDirectory) {
              if (query.isEmpty) {
                rows.add(
                  FileTreeItem(
                    name: node.name,
                    depth: depth,
                    isFolder: true,
                    isExpanded: explorer.isExpanded(node.path),
                    onTap: () => explorer.toggleFolder(node.path),
                  ),
                );
                if (explorer.isExpanded(node.path)) {
                  walk(node.children, depth + 1);
                }
              } else {
                walk(node.children, depth); // flatten while filtering
              }
            } else {
              if (query.isNotEmpty &&
                  !node.name.toLowerCase().contains(query)) {
                continue;
              }
              rows.add(
                FileTreeItem(
                  name: node.name,
                  depth: query.isEmpty ? depth : 0,
                  isFolder: false,
                  isSelected: explorer.selectedPath == node.path,
                  onTap: () {
                    explorer.selectFile(node.path);
                    scope.editor.open(node.path);
                  },
                ),
              );
            }
          }
        }

        walk(explorer.roots, 0);

        if (rows.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              query.isEmpty
                  ? 'This stash is empty.\nCreate a note or folder to begin.'
                  : 'No notes match your search.',
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: NotelyColors.textFaint,
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: rows,
        );
      },
    );
  }
}
