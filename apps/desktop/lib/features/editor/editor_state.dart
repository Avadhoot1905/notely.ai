// Editor state, connected to real files.
//
// Opens a file by path (reading from disk), tracks edits in a TextEditingController, and
// autosaves on a short debounce so typing stays snappy (no write-per-keystroke). Switching
// files flushes pending saves first so unsaved content is never lost.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../services/filesystem/file_system_service.dart';

class EditorController extends ChangeNotifier {
  EditorController({FileSystemService? fs})
    : _fs = fs ?? const FileSystemService() {
    text.addListener(_onChanged);
  }

  final FileSystemService _fs;
  final TextEditingController text = TextEditingController();

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
      final content = await _fs.readFile(path);
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

  @override
  void dispose() {
    _saveTimer?.cancel();
    text.removeListener(_onChanged);
    text.dispose();
    super.dispose();
  }
}
