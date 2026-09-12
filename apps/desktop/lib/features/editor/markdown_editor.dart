// Center markdown editor.
//
// A real editable text field (not rich text): markdown syntax stays visible, in a monospace
// face with comfortable line height and horizontal padding. When no note is open it shows a
// calm empty state. No markdown AST / rendering framework — deliberately lightweight for the
// mockup.

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/theme.dart';

class MarkdownEditor extends StatelessWidget {
  const MarkdownEditor({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return Container(
      color: NotelyColors.editor,
      child: AnimatedBuilder(
        animation: scope.editor,
        builder: (context, _) {
          if (!scope.editor.hasOpenNote) {
            return const _EmptyState();
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 40,
                  vertical: 28,
                ),
                child: TextField(
                  controller: scope.editor.text,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  cursorColor: NotelyColors.accent,
                  cursorWidth: 2,
                  style: const TextStyle(
                    fontFamily: kEditorFont,
                    fontFamilyFallback: kEditorFontFallback,
                    fontSize: 14,
                    height: 1.7,
                    color: NotelyColors.textPrimary,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    hintText: 'Start writing…',
                    hintStyle: TextStyle(color: NotelyColors.textFaint),
                  ),
                ),
              ),
            ),
          );
        },
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.description_outlined,
            size: 34,
            color: NotelyColors.textFaint,
          ),
          const SizedBox(height: 14),
          const Text(
            'Select a note',
            style: TextStyle(fontSize: 15, color: NotelyColors.textSecondary),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: () {
              final id = explorer.createNote('Untitled');
              editor.open(id);
            },
            borderRadius: BorderRadius.circular(NotelyDims.radius),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(NotelyDims.radius),
                border: Border.all(color: NotelyColors.border),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 15, color: NotelyColors.textSecondary),
                  SizedBox(width: 6),
                  Text(
                    'New note',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: NotelyColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
