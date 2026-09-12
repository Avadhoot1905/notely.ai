// Compact, dark, native-feeling context menu for the Explorer.
//
// Built on Flutter's [showMenu] so it gets outside-click + Escape dismissal and keyboard
// navigation for free. Styling is kept subtle to match the VS Code / Obsidian look — no large
// cards or floating "AI" treatment. Only the destructive action (Delete) carries a danger tint.
// This file only presents the menu; filesystem work is done by the caller.

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../platform/platform_ui.dart';

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
  final t = context.tokens;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final position = RelativeRect.fromRect(
    Rect.fromPoints(globalPosition, globalPosition),
    Offset.zero & overlay.size,
  );

  PopupMenuItem<ExplorerAction> item(
    ExplorerAction value,
    IconData icon,
    String label, {
    bool danger = false,
  }) {
    final color = danger ? t.danger : t.textSecondary;
    final labelColor = danger ? t.danger : t.textPrimary;
    return PopupMenuItem<ExplorerAction>(
      value: value,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 10),
          Text(label, style: NotelyType.row.copyWith(color: labelColor)),
        ],
      ),
    );
  }

  final divider = PopupMenuDivider(height: 9, color: t.border);

  final items = <PopupMenuEntry<ExplorerAction>>[];
  switch (kind) {
    case ExplorerTargetKind.folder:
      items.addAll([
        item(ExplorerAction.newFile, Icons.note_add_outlined, 'New File'),
        item(
          ExplorerAction.newFolder,
          Icons.create_new_folder_outlined,
          'New Folder',
        ),
        divider,
        item(ExplorerAction.rename, Icons.drive_file_rename_outline, 'Rename'),
        item(
          ExplorerAction.delete,
          Icons.delete_outline,
          'Delete',
          danger: true,
        ),
        divider,
        item(ExplorerAction.copyPath, Icons.link, 'Copy Path'),
        item(
          ExplorerAction.reveal,
          Icons.folder_open_outlined,
          PlatformUi.revealLabel,
        ),
      ]);
    case ExplorerTargetKind.file:
      items.addAll([
        item(ExplorerAction.open, Icons.article_outlined, 'Open'),
        item(ExplorerAction.rename, Icons.drive_file_rename_outline, 'Rename'),
        item(
          ExplorerAction.delete,
          Icons.delete_outline,
          'Delete',
          danger: true,
        ),
        divider,
        item(ExplorerAction.copyPath, Icons.link, 'Copy Path'),
        item(
          ExplorerAction.reveal,
          Icons.folder_open_outlined,
          PlatformUi.revealLabel,
        ),
      ]);
    case ExplorerTargetKind.empty:
      items.addAll([
        item(ExplorerAction.newFile, Icons.note_add_outlined, 'New File'),
        item(
          ExplorerAction.newFolder,
          Icons.create_new_folder_outlined,
          'New Folder',
        ),
        divider,
        item(ExplorerAction.refresh, Icons.refresh, 'Refresh'),
      ]);
  }

  return showMenu<ExplorerAction>(
    context: context,
    position: position,
    color: t.raised,
    elevation: 10,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(NotelyDims.radius),
      side: BorderSide(color: t.borderStrong),
    ),
    items: items,
  );
}
