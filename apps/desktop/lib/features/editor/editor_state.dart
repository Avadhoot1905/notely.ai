// Editor state, connected to real files.
//
// Opens a file by path (reading from disk), tracks edits in a TextEditingController, and
// autosaves on a short debounce so typing stays snappy (no write-per-keystroke). Switching
// files flushes pending saves first so unsaved content is never lost.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../../services/filesystem/file_system_service.dart';
import 'markdown_highlighter.dart';

class EditorController extends ChangeNotifier {
  EditorController({FileSystemService? fs})
    : _fs = fs ?? const FileSystemService() {
    text.addListener(_onChanged);
  }

  final FileSystemService _fs;

  /// Syntax-highlighting controller — the document remains plain editable Markdown.
  final TextEditingController text = MarkdownHighlightingController();

  /// Focus for the editor field, so external actions (e.g. Ask citations) can reveal a
  /// selected passage by focusing the field.
  final FocusNode focusNode = FocusNode(debugLabel: 'editor');

  static const Duration _autosaveDebounce = Duration(milliseconds: 800);

  String? _openPath;
  bool _dirty = false;
  bool _loading = false;
  String? _error;
  Timer? _saveTimer;

  String? get openPath => _openPath;
  bool get hasOpenNote => _openPath != null;
  bool get isDirty => _dirty;
  bool get isLoading => _loading;
  String? get error => _error;

  /// The note's first line — its H1 title, which drives the filename.
  String get firstLine {
    final content = text.text;
    final nl = content.indexOf('\n');
    return nl == -1 ? content : content.substring(0, nl);
  }

  /// Current 1-based caret line/column, for the status bar.
  int _line = 1;
  int _col = 1;
  int get line => _line;
  int get col => _col;

  /// Open [path], flushing any pending save for the previously open file first.
  Future<void> open(String path) async {
    if (_openPath == path) return;
    await _flushSave();
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      // Notely edits in LF: normalize any CRLF/CR on read so Windows-authored files don't carry
      // stray carriage returns into the editor, and saves stay consistently LF across platforms.
      final content = _normalizeNewlines(await _fs.readFile(path));
      _openPath = path;
      _suppressSave(() {
        text.text = content;
        text.selection = TextSelection.collapsed(offset: content.length);
      });
      _dirty = false;
    } on FileSystemException catch (e) {
      _error = 'Could not open file: ${e.message}';
    } finally {
      _loading = false;
      _recomputeCaret();
      notifyListeners();
    }
  }

  /// Replace the open note's content programmatically (e.g. a generated summary) and persist
  /// immediately so the on-disk file matches what the editor shows.
  Future<void> setContent(String markdown) async {
    if (_openPath == null) return;
    _suppressSave(() {
      text.text = markdown;
      text.selection = TextSelection.collapsed(offset: markdown.length);
    });
    _dirty = true; // force the programmatic write (listener was suppressed)
    await saveNow();
    _recomputeCaret();
    notifyListeners();
  }

  /// Select the (0-based, inclusive) line range [startLine]..[endLine] and focus the editor so
  /// the passage scrolls into view and highlights — used when opening an Ask citation.
  void selectLines(int startLine, int endLine) {
    if (_openPath == null) return;
    final content = text.text;
    final lines = content.split('\n');
    var pos = 0;
    var selStart = 0;
    var selEnd = content.length;
    for (var i = 0; i < lines.length; i++) {
      final lineStart = pos;
      final lineEnd = pos + lines[i].length;
      if (i == startLine) selStart = lineStart;
      if (i == endLine) {
        selEnd = lineEnd;
        break;
      }
      pos = lineEnd + 1; // + newline
    }
    final s = selStart.clamp(0, content.length);
    final e = selEnd.clamp(s, content.length);
    text.selection = TextSelection(baseOffset: s, extentOffset: e);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (focusNode.canRequestFocus) focusNode.requestFocus();
    });
    notifyListeners();
  }

  /// Insert [snippet] at the caret (replacing any selection) and leave the caret after it.
  /// Treated as a normal edit, so it marks the note dirty and autosaves.
  void insertText(String snippet) {
    if (_openPath == null) return;
    final value = text.value;
    final sel = value.selection;
    final base = value.text;
    final start = sel.isValid ? sel.start : base.length;
    final end = sel.isValid ? sel.end : base.length;
    final newText = base.replaceRange(start, end, snippet);
    text.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + snippet.length),
    );
  }

  /// Flush the current buffer to disk now.
  Future<void> saveNow() async {
    _saveTimer?.cancel();
    if (_openPath == null || !_dirty) return;
    try {
      await _fs.writeFile(_openPath!, text.text);
      _dirty = false;
      _error = null;
    } on FileSystemException catch (e) {
      _error = 'Could not save file: ${e.message}';
      notifyListeners();
    }
  }

  /// Collapse CRLF and lone CR to LF. Notely's on-disk policy is LF (see [open]).
  static String _normalizeNewlines(String s) =>
      s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  bool _suppressing = false;
  void _suppressSave(VoidCallback fn) {
    _suppressing = true;
    fn();
    _suppressing = false;
  }

  Future<void> _flushSave() => saveNow();

  void _onChanged() {
    _recomputeCaret();
    if (_suppressing || _openPath == null) return;
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_autosaveDebounce, saveNow);
  }

  void _recomputeCaret() {
    final offset = text.selection.baseOffset;
    final upTo = offset < 0
        ? text.text
        : text.text.substring(0, offset.clamp(0, text.text.length));
    final lines = upTo.split('\n');
    final newLine = lines.length;
    final newCol = lines.last.length + 1;
    if (newLine != _line || newCol != _col) {
      _line = newLine;
      _col = newCol;
      notifyListeners();
    }
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// React to the open file (or its containing folder) being moved/renamed on disk. Rebinds
  /// the open path to its new location WITHOUT re-reading from disk, so in-memory (possibly
  /// unsaved) content and dirty state are preserved and future saves target the new path.
  void handlePathMoved(String oldPath, String newPath) {
    final open = _openPath;
    if (open == null) return;
    if (p.equals(open, oldPath)) {
      _openPath = newPath;
      notifyListeners();
    } else if (p.isWithin(oldPath, open)) {
      // The open file lived inside a moved/renamed folder — remap the prefix.
      final rel = p.relative(open, from: oldPath);
      _openPath = p.join(newPath, rel);
      notifyListeners();
    }
  }

  /// React to the open file (or its containing folder) being deleted: close the editor.
  void handlePathDeleted(String path) {
    final open = _openPath;
    if (open == null) return;
    if (p.equals(open, path) || p.isWithin(path, open)) {
      _saveTimer?.cancel();
      _openPath = null;
      _dirty = false;
      _suppressSave(() => text.text = '');
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    text.removeListener(_onChanged);
    text.dispose();
    focusNode.dispose();
    super.dispose();
  }
}
