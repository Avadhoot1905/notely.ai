// A single compact explorer row — folder or note.
//
// Rows are intentionally dense (VS Code / Obsidian explorer), with a subtle hover and a
// clear selected state for the active note. Indentation encodes depth.

import 'package:flutter/material.dart';

import '../../app/theme.dart';

class FileTreeItem extends StatefulWidget {
  const FileTreeItem({
    super.key,
    required this.name,
    required this.depth,
    required this.isFolder,
    this.isExpanded = false,
    this.isSelected = false,
    required this.onTap,
  });

  final String name;
  final int depth;
  final bool isFolder;
  final bool isExpanded;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<FileTreeItem> createState() => _FileTreeItemState();
}

class _FileTreeItemState extends State<FileTreeItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Color bg = widget.isSelected
        ? NotelyColors.selection
        : (_hover ? NotelyColors.hover : Colors.transparent);

    final Color fg = widget.isSelected || _hover
        ? NotelyColors.textPrimary
        : NotelyColors.textSecondary;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: NotelyDims.rowHeight,
          padding: EdgeInsets.only(left: 8.0 + widget.depth * 14, right: 8),
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              left: BorderSide(
                color: widget.isSelected
                    ? NotelyColors.accent
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: widget.isFolder
                    ? Icon(
                        widget.isExpanded
                            ? Icons.expand_more
                            : Icons.chevron_right,
                        size: 16,
                        color: NotelyColors.textFaint,
                      )
                    : const SizedBox.shrink(),
              ),
              Icon(
                widget.isFolder
                    ? (widget.isExpanded ? Icons.folder_open : Icons.folder)
                    : Icons.description_outlined,
                size: 14,
                color: widget.isFolder
                    ? NotelyColors.textFaint
                    : fg.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.0,
                    color: fg,
                    fontWeight: widget.isSelected
                        ? FontWeight.w500
                        : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
