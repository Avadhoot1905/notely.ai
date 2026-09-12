// Tests for the "first line (H1) == filename" binding.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/editor/editor_state.dart';
import 'package:notely_desktop/features/explorer/explorer_state.dart';
import 'package:path/path.dart' as p;

void main() {
  group('titleToFileName', () {
    test('strips a leading H1 marker', () {
      expect(
        ExplorerController.titleToFileName('# Quantum Physics'),
        'Quantum Physics',
      );
      expect(
        ExplorerController.titleToFileName('Quantum Physics'),
        'Quantum Physics',
      );
    });

    test('keeps spaces and hyphens, drops illegal filename characters', () {
      expect(
        ExplorerController.titleToFileName('Q3: plan/review'),
        'Q3 planreview',
      );
      expect(
        ExplorerController.titleToFileName('well-known ideas'),
        'well-known ideas',
      );
    });

    test('returns null when nothing usable remains', () {
      expect(ExplorerController.titleToFileName(''), isNull);
      expect(ExplorerController.titleToFileName('#   '), isNull);
      expect(ExplorerController.titleToFileName('   '), isNull);
    });
  });

  group('renameForTitle + editor', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('notely_title_');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('editor.firstLine reads the H1 line', () async {
      final path = p.join(root.path, 'Untitled.md');
      await File(path).writeAsString('# Untitled\n\nbody');
      final editor = EditorController();
      await editor.open(path);
      expect(editor.firstLine, '# Untitled');
      editor.dispose();
    });

    test(
      'renaming to match the title moves the file and rebinds the editor',
      () async {
        final path = p.join(root.path, 'Untitled.md');
        await File(path).writeAsString('# Untitled\n');
        final explorer = ExplorerController();
        await explorer.setRoot(root.path);
        final editor = EditorController();
        await editor.open(path);

        // User rewrites the first line.
        editor.text.value = const TextEditingValue(text: '# Quantum Physics\n');
        final title = ExplorerController.titleToFileName(editor.firstLine);
        expect(title, 'Quantum Physics');

        await editor.saveNow();
        final res = await explorer.renameForTitle(editor.openPath!, title!);
        expect(res, isNotNull);
        editor.handlePathMoved(res!.$1, res.$2);

        final expected = p.join(root.path, 'Quantum Physics.md');
        expect(await File(expected).exists(), isTrue);
        expect(await File(path).exists(), isFalse);
        expect(editor.openPath, expected);
        editor.dispose();
      },
    );

    test('no rename when the title already matches the filename', () async {
      final path = p.join(root.path, 'Notes.md');
      await File(path).writeAsString('# Notes\n');
      final explorer = ExplorerController();
      await explorer.setRoot(root.path);

      final res = await explorer.renameForTitle(path, 'Notes');
      expect(res, isNull); // unchanged
      expect(await File(path).exists(), isTrue);
    });

    test('collision keeps the file and reports an error', () async {
      final a = p.join(root.path, 'A.md');
      final b = p.join(root.path, 'B.md');
      await File(a).writeAsString('# A\n');
      await File(b).writeAsString('# B\n');
      final explorer = ExplorerController();
      await explorer.setRoot(root.path);

      final res = await explorer.renameForTitle(a, 'B'); // B.md exists
      expect(res, isNull);
      expect(explorer.error, isNotNull);
      expect(await File(a).exists(), isTrue);
      expect(await File(b).exists(), isTrue);
    });
  });
}
