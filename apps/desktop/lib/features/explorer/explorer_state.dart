// Explorer (file tree) state.
//
// Owns the in-memory tree, which folders are expanded, the selected note, and the current
// filename filter. Presentation (file_tree.dart) reads this and reports user intent back.

import 'package:flutter/foundation.dart';

import '../../mock/mock_files.dart';
import '../../mock/mock_notes.dart';

class ExplorerController extends ChangeNotifier {
  ExplorerController() : _roots = seedWorkStash() {
    // Expand the common top-level folders by default so the tree reads as a real vault.
    _expanded.addAll({
      'Meetings',
      'Meetings/2026',
      'Meetings/2026/September',
      'Projects',
      'Notes',
    });
  }

  List<FileNode> _roots;
  final Set<String> _expanded = {};
  String? _selectedNoteId;
  String _query = '';

  List<FileNode> get roots => _roots;
  String? get selectedNoteId => _selectedNoteId;
  String get query => _query;
  bool get isFiltering => _query.trim().isNotEmpty;

  bool isExpanded(String path) => _expanded.contains(path);

  void toggleFolder(String path) {
    if (!_expanded.remove(path)) _expanded.add(path);
    notifyListeners();
  }

  void selectNote(String noteId) {
    if (_selectedNoteId == noteId) return;
    _selectedNoteId = noteId;
    notifyListeners();
  }

  void setQuery(String q) {
    _query = q;
    notifyListeners();
  }

  /// Create a new markdown note under the top-level "Notes" folder and select it.
  /// Purely in-memory; the engine will own real file creation later.
  String createNote(String rawName) {
    final name = rawName.trim().isEmpty
        ? 'Untitled.md'
        : (rawName.trim().endsWith('.md')
              ? rawName.trim()
              : '${rawName.trim()}.md');
    final id = 'note-${name.toLowerCase()}-${_roots.length}-${name.hashCode}';
    mockNotes[id] = '# ${name.replaceAll('.md', '')}\n\n';

    final newRoots = List<FileNode>.from(_roots);
    final notesIdx = newRoots.indexWhere(
      (n) => n.isFolder && n.name == 'Notes',
    );
    final note = FileNode.note(name, id);
    if (notesIdx >= 0) {
      final notes = newRoots[notesIdx];
      newRoots[notesIdx] = FileNode.folder(notes.name, [
        ...notes.children,
        note,
      ]);
    } else {
      newRoots.add(FileNode.folder('Notes', [note]));
    }
    _roots = newRoots;
    _expanded.add('Notes');
    _selectedNoteId = id;
    notifyListeners();
    return id;
  }
}
