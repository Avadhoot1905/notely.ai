// A single compact explorer row — folder or note.
//
// Dense, VS Code / Obsidian-style rows. The active note gets a small accent marker + tint (not
// just a flat highlight); hover is a subtle animated surface; a valid drop target reads as a
// soft accent fill. Indentation encodes depth.

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
    this.isDropTarget = false,
    this.isImage = false,
    required this.onTap,
    this.onSecondaryTapDown,
  });

  final String name;
  final int depth;
  final bool isFolder;
  final bool isExpanded;
  final bool isSelected;
  final bool isImage;

  /// Highlighted as a valid drag-and-drop destination.
  final bool isDropTarget;
  final VoidCallback onTap;
  final void Function(Offset globalPosition)? onSecondaryTapDown;

  @override
  State<FileTreeItem> createState() => _FileTreeItemState();
}

class _FileTreeItemState extends State<FileTreeItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    final Color bg = widget.isDropTarget
        ? t.accentMuted
        : widget.isSelected
        ? t.selection
        : (_hover ? t.hover : Colors.transparent);

    final Color fg = widget.isSelected
        ? t.textPrimary
        : (_hover || widget.isDropTarget ? t.textPrimary : t.textSecondary);

    final Color markerColor = widget.isSelected
        ? t.accent
        : (widget.isDropTarget ? t.accent : Colors.transparent);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapDown: widget.onSecondaryTapDown == null
            ? null
            : (d) => widget.onSecondaryTapDown!(d.globalPosition),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: NotelyMotion.fast,
          height: NotelyDims.rowHeight,
          padding: EdgeInsets.only(left: 8.0 + widget.depth * 14, right: 8),
          decoration: BoxDecoration(
            color: bg,
            border: Border(left: BorderSide(color: markerColor, width: 2)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: widget.isFolder
                    ? Icon(
                        widget.isExpanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 16,
                        color: t.textFaint,
                      )
                    : const SizedBox.shrink(),
              ),
              Icon(
                widget.isFolder
                    ? (widget.isExpanded
                          ? Icons.folder_open_rounded
                          : Icons.folder_rounded)
                    : (widget.isImage
                          ? Icons.image_outlined
                          : Icons.article_outlined),
                size: 14,
                color: widget.isFolder
                    ? (widget.isSelected || _hover ? t.accent : t.textFaint)
                    : fg.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.name,
                  overflow: TextOverflow.ellipsis,
                  style: NotelyType.row.copyWith(
                    color: fg,
                    fontWeight: widget.isSelected
                        ? FontWeight.w600
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
