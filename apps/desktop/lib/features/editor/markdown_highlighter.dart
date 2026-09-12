// A TextEditingController that syntax-highlights Markdown *in place*.
//
// The document stays plain, fully-editable Markdown — we never hide or rewrite characters, so
// the cursor and selection behave exactly like a normal text field. We only override how the
// text is painted: headings get a restrained size/weight hierarchy, list bullets/checkboxes,
// blockquotes, inline `code`, **bold** and *italic* get subtle treatment. This gives the editor
// real personality without turning it into a rich-text/WYSIWYG editor.

import 'package:flutter/material.dart';

import '../../app/theme.dart';

class MarkdownHighlightingController extends TextEditingController {
  MarkdownHighlightingController({super.text});

  static final _heading = RegExp(r'^(#{1,6})(.*)$');
  static final _quote = RegExp(r'^(\s*>)(.*)$');
  static final _listItem = RegExp(r'^(\s*)([-*+])(\s+)(\[[ xX]\]\s+)?(.*)$');
  static final _inline = RegExp(
    r'(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|(_[^_]+_)',
  );

  static const _headingScale = [1.55, 1.34, 1.18, 1.08, 1.04, 1.0];

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final t = context.tokens;
    final lines = text.split('\n');
    final children = <InlineSpan>[];

    for (var i = 0; i < lines.length; i++) {
      children.addAll(_spansForLine(lines[i], base, t));
      if (i != lines.length - 1) {
        children.add(TextSpan(text: '\n', style: base));
      }
    }
    return TextSpan(style: base, children: children);
  }

  List<InlineSpan> _spansForLine(String line, TextStyle base, NotelyTokens t) {
    final syntax = base.copyWith(color: t.editorSyntax);

    final heading = _heading.firstMatch(line);
    if (heading != null) {
      final hashes = heading.group(1)!;
      final rest = heading.group(2)!;
      final scale = _headingScale[(hashes.length - 1).clamp(0, 5)];
      final headingStyle = base.copyWith(
        fontSize: (base.fontSize ?? 14) * scale,
        fontWeight: FontWeight.w700,
        color: t.textPrimary,
        letterSpacing: -0.3,
        height: 1.3,
      );
      return [
        TextSpan(
          text: hashes,
          style: headingStyle.copyWith(color: t.editorSyntax),
        ),
        TextSpan(text: rest, style: headingStyle),
      ];
    }

    final quote = _quote.firstMatch(line);
    if (quote != null) {
      return [
        TextSpan(text: quote.group(1), style: syntax),
        TextSpan(
          text: quote.group(2),
          style: base.copyWith(
            color: t.textSecondary,
            fontStyle: FontStyle.italic,
          ),
        ),
      ];
    }

    final list = _listItem.firstMatch(line);
    if (list != null) {
      final indent = list.group(1)!;
      final bullet = list.group(2)!;
      final space = list.group(3)!;
      final box = list.group(4); // "[ ] " / "[x] " or null
      final rest = list.group(5)!;
      final checked = box != null && (box.contains('x') || box.contains('X'));
      final spans = <InlineSpan>[
        TextSpan(text: indent, style: base),
        TextSpan(
          text: bullet,
          style: syntax.copyWith(fontWeight: FontWeight.w700),
        ),
        TextSpan(text: space, style: base),
      ];
      if (box != null) {
        spans.add(
          TextSpan(
            text: box,
            style: base.copyWith(
              color: checked ? t.accent : t.textFaint,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }
      final restStyle = checked ? base.copyWith(color: t.textFaint) : base;
      spans.addAll(_inlineSpans(rest, restStyle, t));
      return spans;
    }

    return _inlineSpans(line, base, t);
  }

  /// Split a line into inline spans for `code`, **bold**, *italic*, _italic_.
  List<InlineSpan> _inlineSpans(String line, TextStyle base, NotelyTokens t) {
    if (line.isEmpty) return [TextSpan(text: line, style: base)];
    final spans = <InlineSpan>[];
    var index = 0;
    for (final m in _inline.allMatches(line)) {
      if (m.start > index) {
        spans.add(TextSpan(text: line.substring(index, m.start), style: base));
      }
      final token = m.group(0)!;
      if (token.startsWith('`')) {
        spans.add(
          TextSpan(
            text: token,
            style: base.copyWith(
              color: t.textPrimary,
              backgroundColor: t.raised,
            ),
          ),
        );
      } else if (token.startsWith('**')) {
        spans.add(
          TextSpan(
            text: token,
            style: base.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: token,
            style: base.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      }
      index = m.end;
    }
    if (index < line.length) {
      spans.add(TextSpan(text: line.substring(index), style: base));
    }
    return spans;
  }
}
