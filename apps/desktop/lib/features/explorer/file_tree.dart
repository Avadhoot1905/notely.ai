// The explorer file tree.
//
// Flattens the [FileNode] tree into visible rows based on which folders are expanded, and
// renders them as compact [FileTreeItem]s. When a filename filter is active, it shows all
// notes whose name matches (folders implicitly expanded).

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../mock/mock_files.dart';
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

        void walk(List<FileNode> nodes, int depth, String path) {
          for (final node in nodes) {
            final nodePath = '$path/${node.name}';
            if (node.isFolder) {
              if (query.isEmpty) {
                rows.add(
                  FileTreeItem(
                    name: node.name,
                    depth: depth,
                    isFolder: true,
                    isExpanded: explorer.isExpanded(nodePath.substring(1)),
                    onTap: () => explorer.toggleFolder(nodePath.substring(1)),
                  ),
                );
                if (explorer.isExpanded(nodePath.substring(1))) {
                  walk(node.children, depth + 1, nodePath);
                }
              } else {
                // While filtering, flatten: recurse without rendering the folder row.
                walk(node.children, depth, nodePath);
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
                  isSelected: explorer.selectedNoteId == node.noteId,
                  onTap: () {
                    explorer.selectNote(node.noteId!);
                    scope.editor.open(node.noteId!);
                  },
                ),
              );
            }
          }
        }

        walk(explorer.roots, 0, '');

        if (rows.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'No notes match your search.',
              style: TextStyle(fontSize: 12, color: NotelyColors.textFaint),
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
