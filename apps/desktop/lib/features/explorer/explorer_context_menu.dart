// Compact, dark, native-feeling context menu for the Explorer.
//
// Built on Flutter's [showMenu] so it gets outside-click + Escape dismissal and keyboard
// navigation for free. Styling is kept subtle to match the VS Code / Obsidian look — no large
// cards or floating "AI" treatment. This file only describes and presents the menu; the actual
// filesystem work is done by the caller via the ExplorerController.

import 'package:flutter/material.dart';

import '../../app/theme.dart';

enum ExplorerAction {
  open,
  newFile,
  newFolder,
  rename,
  delete,
  copyPath,
  reveal,
  refresh,
}

/// What was right-clicked, so the menu can be built contextually.
enum ExplorerTargetKind { folder, file, empty }

/// Show the Explorer context menu at [globalPosition]. Returns the chosen action, or null if
/// dismissed.
Future<ExplorerAction?> showExplorerContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required ExplorerTargetKind kind,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final position = RelativeRect.fromRect(
    Rect.fromPoints(globalPosition, globalPosition),
    Offset.zero & overlay.size,
  );

  final items = <PopupMenuEntry<ExplorerAction>>[];
  switch (kind) {
    case ExplorerTargetKind.folder:
      items.addAll([
        _item(ExplorerAction.newFile, Icons.note_add_outlined, 'New File'),
        _item(
          ExplorerAction.newFolder,
          Icons.create_new_folder_outlined,
          'New Folder',
        ),
        const PopupMenuDivider(height: 1),
        _item(ExplorerAction.rename, Icons.drive_file_rename_outline, 'Rename'),
        _item(ExplorerAction.delete, Icons.delete_outline, 'Delete'),
        const PopupMenuDivider(height: 1),
        _item(ExplorerAction.copyPath, Icons.link, 'Copy Path'),
        _item(
          ExplorerAction.reveal,
          Icons.folder_open_outlined,
          'Reveal in Finder',
        ),
      ]);
    case ExplorerTargetKind.file:
      items.addAll([
        _item(ExplorerAction.open, Icons.description_outlined, 'Open'),
        _item(ExplorerAction.rename, Icons.drive_file_rename_outline, 'Rename'),
        _item(ExplorerAction.delete, Icons.delete_outline, 'Delete'),
        const PopupMenuDivider(height: 1),
        _item(ExplorerAction.copyPath, Icons.link, 'Copy Path'),
        _item(
          ExplorerAction.reveal,
          Icons.folder_open_outlined,
          'Reveal in Finder',
        ),
      ]);
    case ExplorerTargetKind.empty:
      items.addAll([
        _item(ExplorerAction.newFile, Icons.note_add_outlined, 'New File'),
        _item(
          ExplorerAction.newFolder,
          Icons.create_new_folder_outlined,
          'New Folder',
        ),
        const PopupMenuDivider(height: 1),
        _item(ExplorerAction.refresh, Icons.refresh, 'Refresh'),
      ]);
  }

  return showMenu<ExplorerAction>(
    context: context,
    position: position,
    color: NotelyColors.raised,
    elevation: 8,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(NotelyDims.radius),
      side: const BorderSide(color: NotelyColors.borderStrong),
    ),
    items: items,
  );
}

PopupMenuItem<ExplorerAction> _item(
  ExplorerAction value,
  IconData icon,
  String label,
) {
  return PopupMenuItem<ExplorerAction>(
    value: value,
    height: 32,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        Icon(icon, size: 14, color: NotelyColors.textSecondary),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12.5,
            color: NotelyColors.textPrimary,
          ),
        ),
      ],
    ),
  );
}
