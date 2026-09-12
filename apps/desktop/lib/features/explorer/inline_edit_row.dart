// Inline name input used for creating and renaming explorer items.
//
// Matches the compact row metrics of [FileTreeItem] so the tree doesn't jump. Enter confirms,
// Escape cancels, and losing focus confirms a non-empty value (VS Code-like). Kept purely
// presentational — it reports the entered name; the controller performs the filesystem work.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';

class InlineEditRow extends StatefulWidget {
  const InlineEditRow({
    super.key,
    required this.depth,
    required this.isFolder,
    required this.onSubmit,
    required this.onCancel,
    this.initialText = '',
  });

  final int depth;
  final bool isFolder;
  final String initialText;
  final void Function(String name) onSubmit;
  final VoidCallback onCancel;

  @override
  State<InlineEditRow> createState() => _InlineEditRowState();
}

class _InlineEditRowState extends State<InlineEditRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );
  final FocusNode _focus = FocusNode();
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
      // Preselect the base name (excluding any .md) so typing replaces it.
      final text = _controller.text;
      final dot = text.toLowerCase().endsWith('.md')
          ? text.length - 3
          : text.length;
      _controller.selection = TextSelection(baseOffset: 0, extentOffset: dot);
    });
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus && !_done) {
      // Confirm on blur when something was typed, else cancel.
      final value = _controller.text.trim();
      _finish(value.isEmpty ? null : value);
    }
  }

  void _finish(String? value) {
    if (_done) return;
    _done = true;
    if (value == null) {
      widget.onCancel();
    } else {
      widget.onSubmit(value);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      height: NotelyDims.rowHeight,
      padding: EdgeInsets.only(left: 8.0 + widget.depth * 14, right: 8),
      decoration: BoxDecoration(
        color: t.raised,
        border: Border(left: BorderSide(color: t.accent, width: 2)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 16),
          Icon(
            widget.isFolder ? Icons.folder_rounded : Icons.article_outlined,
            size: 14,
            color: t.accent,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    _finish(null),
              },
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                style: NotelyType.row.copyWith(color: t.textPrimary),
                cursorColor: t.accent,
                cursorHeight: 14,
                decoration: InputDecoration(
                  isDense: true,
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: 'name',
                  hintStyle: TextStyle(color: t.textFaint),
                ),
                onSubmitted: (v) => _finish(v.trim().isEmpty ? null : v.trim()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
