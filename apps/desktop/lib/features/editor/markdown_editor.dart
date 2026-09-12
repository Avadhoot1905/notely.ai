// Center markdown editor — the visual heart of Notely.
//
// A real editable text field whose Markdown stays visible, but syntax-highlighted in place by
// [MarkdownHighlightingController] (headings, lists, quotes, code, emphasis). Monospace face,
// generous line height and horizontal padding for comfortable long-form editing. When no note
// is open, a calm, typographic empty state.
//
// Images: an "Insert image" action (top-right affordance + Cmd/Ctrl+Shift+I) copies a picked
// image into the stash's attachments folder and inserts a portable relative Markdown link, so
// the image is retained beside the note that references it.

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../app/app_scope.dart';
import '../../app/theme.dart';
import '../../services/filesystem/fs_node.dart';

class MarkdownEditor extends StatelessWidget {
  const MarkdownEditor({super.key});

  /// Pick an image, copy it into the stash, and insert a relative Markdown link at the caret.
  static Future<void> insertImage(BuildContext context) async {
    final scope = AppScope.of(context);
    final editor = scope.editor;
    if (!editor.hasOpenNote) return;

    final group = XTypeGroup(
      label: 'Images',
      extensions: FsNode.imageExtensions.toList(),
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;

    final dest = await scope.explorer.importImage(file.path);
    if (dest == null) return;

    // Build a link relative to the open note so it stays valid if the stash moves.
    final noteDir = p.dirname(editor.openPath!);
    final rel = p.relative(dest, from: noteDir).replaceAll(r'\', '/');
    final alt = p.basenameWithoutExtension(dest);
    editor.insertText('![$alt]($rel)');
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final t = context.tokens;
    return Container(
      color: t.editor,
      child: AnimatedBuilder(
        animation: scope.editor,
        builder: (context, _) {
          if (scope.editor.isLoading) {
            return Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: t.textFaint,
                ),
              ),
            );
          }
          if (!scope.editor.hasOpenNote) {
            return const _EmptyState();
          }
          return Stack(
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 44,
                      vertical: 30,
                    ),
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(
                          LogicalKeyboardKey.keyI,
                          meta: true,
                          shift: true,
                        ): () =>
                            insertImage(context),
                        const SingleActivator(
                          LogicalKeyboardKey.keyI,
                          control: true,
                          shift: true,
                        ): () =>
                            insertImage(context),
                      },
                      child: TextField(
                        controller: scope.editor.text,
                        focusNode: scope.editor.focusNode,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        cursorColor: t.accent,
                        cursorWidth: 2,
                        cursorRadius: const Radius.circular(1),
                        style: TextStyle(
                          fontFamily: kEditorFont,
                          fontFamilyFallback: kEditorFontFallback,
                          fontSize: 14,
                          height: 1.75,
                          color: t.textPrimary,
                        ),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          isCollapsed: true,
                          hintText: 'Start writing…',
                          hintStyle: TextStyle(color: t.textFaint),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 10,
                right: 14,
                child: _EditorAction(
                  icon: Icons.image_outlined,
                  tip: 'Insert image  (⇧⌘I)',
                  onTap: () => insertImage(context),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A subtle icon affordance pinned in the editor corner.
class _EditorAction extends StatefulWidget {
  const _EditorAction({
    required this.icon,
    required this.tip,
    required this.onTap,
  });
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  State<_EditorAction> createState() => _EditorActionState();
}

class _EditorActionState extends State<_EditorAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: widget.tip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: NotelyMotion.fast,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _hover ? t.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(NotelyDims.radiusSmall),
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: _hover ? t.textSecondary : t.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final explorer = AppScope.of(context).explorer;
    final editor = AppScope.of(context).editor;
    final t = context.tokens;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'No note selected',
            style: NotelyType.dialogTitle.copyWith(color: t.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            'Select a note from the Explorer, or create one.',
            style: TextStyle(fontSize: 13, color: t.textFaint, height: 1.4),
          ),
          const SizedBox(height: 20),
          _NewNoteButton(
            onTap: () async {
              final path = await explorer.createFile('Untitled');
              if (path != null) await editor.open(path);
            },
          ),
        ],
      ),
    );
  }
}

class _NewNoteButton extends StatefulWidget {
  const _NewNoteButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_NewNoteButton> createState() => _NewNoteButtonState();
}

class _NewNoteButtonState extends State<_NewNoteButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: NotelyMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: _hover ? t.selection : Colors.transparent,
            borderRadius: BorderRadius.circular(NotelyDims.radius),
            border: Border.all(color: _hover ? t.accent : t.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add,
                size: 15,
                color: _hover ? t.accent : t.textSecondary,
              ),
              const SizedBox(width: 7),
              Text(
                'New note',
                style: NotelyType.button.copyWith(color: t.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
