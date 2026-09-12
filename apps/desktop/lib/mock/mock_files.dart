// Mock filesystem tree for a seeded "Work" stash.
//
// This is pure in-memory data standing in for what the Rust engine will later enumerate from
// a real Stash folder. The tree shape (folders + markdown notes) mirrors the product spec.
// Replacing this with real data means swapping the source of [seedWorkStash]; the widgets
// that render [FileNode] stay unchanged.

import 'mock_notes.dart';

/// A node in the explorer tree — either a folder (with [children]) or a markdown note.
class FileNode {
  FileNode.folder(this.name, this.children) : isFolder = true, noteId = null;
  FileNode.note(this.name, this.noteId) : isFolder = false, children = const [];

  final String name;
  final bool isFolder;
  final List<FileNode> children;

  /// Key into [mockNotes] for the note's markdown body. Null for folders.
  final String? noteId;
}

/// Builds the seeded "Work" stash tree. Called once when a stash is opened.
List<FileNode> seedWorkStash() => [
  FileNode.folder('Meetings', [
    FileNode.folder('2026', [
      FileNode.folder('September', [
        FileNode.note('Team Sync.md', NoteIds.teamSync),
        FileNode.note('Product Review.md', NoteIds.productReview),
        FileNode.note('Q3 Planning.md', NoteIds.q3Planning),
      ]),
    ]),
  ]),
  FileNode.folder('Projects', [
    FileNode.folder('Notely', [
      FileNode.note('Architecture.md', NoteIds.architecture),
      FileNode.note('Roadmap.md', NoteIds.roadmap),
    ]),
    FileNode.folder('QShield', [
      FileNode.note('Notes.md', NoteIds.qshieldNotes),
    ]),
  ]),
  FileNode.folder('Notes', [
    FileNode.note('Ideas.md', NoteIds.ideas),
    FileNode.note('TODO.md', NoteIds.todo),
  ]),
];
