// Editor state.
//
// Holds the markdown body for the open note in a TextEditingController and caches per-note
// edits in memory so switching files preserves unsaved changes. No persistence — the engine
// will own saving to disk later.

import 'package:flutter/widgets.dart';

import '../../mock/mock_notes.dart';

class EditorController extends ChangeNotifier {
  final TextEditingController text = TextEditingController();
  final Map<String, String> _edits = {};

  String? _openNoteId;
  String? get openNoteId => _openNoteId;
  bool get hasOpenNote => _openNoteId != null;

  /// Current 1-based caret line/column, for the status bar.
  int _line = 1;
  int _col = 1;
  int get line => _line;
  int get col => _col;

  EditorController() {
    text.addListener(_onChanged);
  }

  void open(String noteId) {
    if (_openNoteId == noteId) return;
    // Stash edits from the previously open note.
    if (_openNoteId != null) _edits[_openNoteId!] = text.text;
    _openNoteId = noteId;
    text.text = _edits[noteId] ?? mockNotes[noteId] ?? '';
    text.selection = TextSelection.collapsed(offset: text.text.length);
    _recomputeCaret();
    notifyListeners();
  }

  void _onChanged() {
    if (_openNoteId != null) _edits[_openNoteId!] = text.text;
    _recomputeCaret();
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

  @override
  void dispose() {
    text.removeListener(_onChanged);
    text.dispose();
    super.dispose();
  }
}
