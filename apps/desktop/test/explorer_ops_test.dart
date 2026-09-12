// Unit tests for Explorer move/rename/delete semantics and editor path rebinding.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/editor/editor_state.dart';
import 'package:notely_desktop/features/explorer/explorer_state.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('notely_ops_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<ExplorerController> explorerWith(Map<String, String?> layout) async {
    // Keys ending with '/' are folders; others are files with the given content.
    for (final entry in layout.entries) {
      final path = p.join(root.path, entry.key);
      if (entry.key.endsWith('/')) {
        await Directory(path).create(recursive: true);
      } else {
        await File(path).create(recursive: true);
        await File(path).writeAsString(entry.value ?? '');
      }
    }
    final c = ExplorerController();
    await c.setRoot(root.path);
    return c;
  }

  test('rename changes the path on disk', () async {
    final c = await explorerWith({'a.md': '# A'});
    c.beginRename(p.join(root.path, 'a.md'));
    final res = await c.confirmRename('b');
    expect(res, isNotNull);
    expect(res!.$2, p.join(root.path, 'b.md'));
    expect(await File(p.join(root.path, 'b.md')).exists(), isTrue);
    expect(await File(p.join(root.path, 'a.md')).exists(), isFalse);
  });

  test('move relocates a file into a folder (real fs move)', () async {
    final c = await explorerWith({'Notes/': null, 'a.md': '# A'});
    final res = await c.move(
      p.join(root.path, 'a.md'),
      destDir: p.join(root.path, 'Notes'),
    );
    expect(res.status, MoveStatus.moved);
    expect(await File(p.join(root.path, 'Notes', 'a.md')).exists(), isTrue);
    expect(await File(p.join(root.path, 'a.md')).exists(), isFalse);
  });

  test('move a folder into another folder', () async {
    final c = await explorerWith({'QShield/': null, 'Notes/': null});
    final res = await c.move(
      p.join(root.path, 'QShield'),
      destDir: p.join(root.path, 'Notes'),
    );
    expect(res.status, MoveStatus.moved);
    expect(
      await Directory(p.join(root.path, 'Notes', 'QShield')).exists(),
      isTrue,
    );
  });

  test('moving a folder into itself/descendant is invalid', () async {
    final c = await explorerWith({'Notely/': null, 'Notely/Docs/': null});
    final intoSelf = await c.move(
      p.join(root.path, 'Notely'),
      destDir: p.join(root.path, 'Notely'),
    );
    expect(intoSelf.status, MoveStatus.invalid);

    final intoChild = await c.move(
      p.join(root.path, 'Notely'),
      destDir: p.join(root.path, 'Notely', 'Docs'),
    );
    expect(intoChild.status, MoveStatus.invalid);
  });

  test('moving to the same directory is a no-op', () async {
    final c = await explorerWith({'a.md': '# A'});
    final res = await c.move(p.join(root.path, 'a.md'), destDir: root.path);
    expect(res.status, MoveStatus.noop);
  });

  test('name collision is reported, not silently overwritten', () async {
    final c = await explorerWith({
      'Notes/': null,
      'Notes/a.md': 'dest',
      'a.md': 'src',
    });
    final res = await c.move(
      p.join(root.path, 'a.md'),
      destDir: p.join(root.path, 'Notes'),
    );
    expect(res.status, MoveStatus.collision);
    // Both still exist; nothing overwritten.
    expect(await File(p.join(root.path, 'a.md')).readAsString(), 'src');
    expect(
      await File(p.join(root.path, 'Notes', 'a.md')).readAsString(),
      'dest',
    );

    // Replacing is explicit.
    final replaced = await c.move(
      p.join(root.path, 'a.md'),
      destDir: p.join(root.path, 'Notes'),
      replace: true,
    );
    expect(replaced.status, MoveStatus.moved);
    expect(
      await File(p.join(root.path, 'Notes', 'a.md')).readAsString(),
      'src',
    );
  });

  test('move back to the stash root', () async {
    final c = await explorerWith({'Meetings/': null, 'Meetings/x.md': '# X'});
    final res = await c.move(
      p.join(root.path, 'Meetings', 'x.md'),
      destDir: root.path,
    );
    expect(res.status, MoveStatus.moved);
    expect(await File(p.join(root.path, 'x.md')).exists(), isTrue);
  });

  test('delete removes the file', () async {
    final c = await explorerWith({'a.md': '# A'});
    final ok = await c.delete(p.join(root.path, 'a.md'));
    expect(ok, isTrue);
    expect(await File(p.join(root.path, 'a.md')).exists(), isFalse);
  });

  test(
    'editor rebinds open path on move and preserves unsaved content',
    () async {
      final path = p.join(root.path, 'a.md');
      await File(path).writeAsString('# A');
      await Directory(p.join(root.path, 'Notes')).create();

      final editor = EditorController();
      await editor.open(path);
      // Simulate an unsaved edit.
      editor.text.text = '# A edited';
      expect(editor.isDirty, isTrue);

      final newPath = p.join(root.path, 'Notes', 'a.md');
      editor.handlePathMoved(path, newPath);
      expect(editor.openPath, newPath);
      expect(editor.text.text, '# A edited'); // content preserved
      expect(editor.isDirty, isTrue);

      editor.dispose();
    },
  );

  test('editor closes when the open file is deleted', () async {
    final path = p.join(root.path, 'a.md');
    await File(path).writeAsString('# A');
    final editor = EditorController();
    await editor.open(path);
    editor.handlePathDeleted(path);
    expect(editor.hasOpenNote, isFalse);
    editor.dispose();
  });

  test('editor rebinds when an ancestor folder is renamed', () async {
    await Directory(p.join(root.path, 'Notely')).create();
    final path = p.join(root.path, 'Notely', 'Arch.md');
    await File(path).writeAsString('# Arch');
    final editor = EditorController();
    await editor.open(path);

    editor.handlePathMoved(
      p.join(root.path, 'Notely'),
      p.join(root.path, 'Notely2'),
    );
    expect(editor.openPath, p.join(root.path, 'Notely2', 'Arch.md'));
    editor.dispose();
  });
}
