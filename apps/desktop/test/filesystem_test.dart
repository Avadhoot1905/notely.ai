// Unit tests for the real filesystem-backed explorer + editor and the stash store.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/editor/editor_state.dart';
import 'package:notely_desktop/features/explorer/explorer_state.dart';
import 'package:notely_desktop/features/stash/stash_state.dart';
import 'package:notely_desktop/services/filesystem/file_system_service.dart';
import 'package:notely_desktop/services/stash/stash_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('notely_test_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  test('FileSystemService lists dirs + md files, skips others', () async {
    const fs = FileSystemService();
    await File(p.join(tempRoot.path, 'a.md')).writeAsString('# A');
    await File(p.join(tempRoot.path, 'ignore.txt')).writeAsString('x');
    await Directory(p.join(tempRoot.path, 'Notes')).create();

    final tree = await fs.readTree(tempRoot.path);
    final names = tree.map((n) => n.name).toList();
    expect(names, contains('Notes'));
    expect(names, contains('a.md'));
    expect(names, isNot(contains('ignore.txt')));
    // Directories sort before files.
    expect(tree.first.isDirectory, isTrue);
  });

  test('ExplorerController creates files and folders on disk', () async {
    final explorer = ExplorerController();
    await explorer.setRoot(tempRoot.path);

    final folder = await explorer.createFolder('Projects');
    expect(folder, isNotNull);
    expect(await Directory(folder!).exists(), isTrue);

    final file = await explorer.createFile('Ideas', dirPath: folder);
    expect(file, isNotNull);
    expect(p.basename(file!), 'Ideas.md');
    expect(await File(file).exists(), isTrue);
    expect(explorer.selectedPath, file);
  });

  test(
    'EditorController reads, autosave-flushes, and writes content',
    () async {
      const fs = FileSystemService();
      final path = p.join(tempRoot.path, 'note.md');
      await File(path).writeAsString('# Note\n');

      final editor = EditorController(fs: fs);
      await editor.open(path);
      expect(editor.text.text, '# Note\n');

      // Programmatic content (e.g. a summary) persists immediately.
      await editor.setContent('# Note\n\n## Summary\nDone.');
      expect(await File(path).readAsString(), contains('## Summary'));

      editor.dispose();
    },
  );

  test('EditorController surfaces an error for a missing file', () async {
    final editor = EditorController();
    await editor.open(p.join(tempRoot.path, 'missing.md'));
    expect(editor.error, isNotNull);
    expect(editor.hasOpenNote, isFalse);
    editor.dispose();
  });

  test('StashStore round-trips and StashController restores', () async {
    final store = StashStore();
    await store.save(StashConfig(name: 'Work', path: tempRoot.path));

    final controller = StashController(store: store);
    await controller.restore();
    expect(controller.isOpen, isTrue);
    expect(controller.name, 'Work');
    expect(controller.path, tempRoot.path);

    await controller.close();
    expect(controller.isOpen, isFalse);
    expect(await store.load(), isNull);
  });
}
