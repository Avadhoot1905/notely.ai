// Cross-platform filesystem behaviour: case-only renames on case-insensitive filesystems,
// Unicode / spaces / punctuation in names, nested moves + conflicts, line-ending preservation,
// and the file watcher abstraction (real dart:io impl + no-op).

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/editor/editor_state.dart';
import 'package:notely_desktop/features/explorer/explorer_state.dart';
import 'package:notely_desktop/services/filesystem/file_system_service.dart';
import 'package:notely_desktop/services/filesystem/file_watcher_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempRoot;
  const fs = FileSystemService();

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('notely_xplat_');
  });
  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  group('case-only rename (safe on macOS/Windows case-insensitive FS)', () {
    test(
      'renames a file to a different case without a false collision',
      () async {
        final path = p.join(tempRoot.path, 'notes.md');
        await File(path).writeAsString('# Notes');

        final renamed = await fs.rename(path, 'Notes');
        expect(p.basename(renamed), 'Notes.md');
        // The content survived and there is exactly one file (no stray duplicate).
        expect(await File(renamed).readAsString(), '# Notes');
        final entries = Directory(
          tempRoot.path,
        ).listSync().map((e) => p.basename(e.path)).toList();
        expect(entries.where((n) => n.toLowerCase() == 'notes.md').length, 1);
      },
    );

    test('renames a folder to a different case', () async {
      final dir = p.join(tempRoot.path, 'projects');
      await Directory(dir).create();
      await File(p.join(dir, 'a.md')).writeAsString('x');

      final renamed = await fs.rename(dir, 'Projects');
      expect(p.basename(renamed), 'Projects');
      expect(await File(p.join(renamed, 'a.md')).readAsString(), 'x');
    });

    test(
      'ExplorerController.move reports no collision for a case-only change',
      () async {
        final path = p.join(tempRoot.path, 'todo.md');
        await File(path).writeAsString('x');
        final explorer = ExplorerController();
        await explorer.setRoot(tempRoot.path);

        final result = await explorer.move(
          path,
          destDir: tempRoot.path,
          renameTo: 'Todo',
        );
        expect(result.status, MoveStatus.moved);
        expect(p.basename(result.newPath!), 'Todo.md');
      },
    );
  });

  test('a genuine collision is still rejected', () async {
    await File(p.join(tempRoot.path, 'a.md')).writeAsString('1');
    await File(p.join(tempRoot.path, 'b.md')).writeAsString('2');
    expect(
      () => fs.rename(p.join(tempRoot.path, 'a.md'), 'b'),
      throwsA(isA<FileSystemException>()),
    );
  });

  group('Unicode, spaces and punctuation in names', () {
    test('creates, reads and renames files with tricky names', () async {
      final created = await fs.createFile(tempRoot.path, 'Café — notes (v2)');
      expect(await File(created).exists(), isTrue);
      expect(p.basename(created), 'Café — notes (v2).md');

      await fs.writeFile(created, '# Café ☕ 日本語');
      expect(await fs.readFile(created), '# Café ☕ 日本語');

      final renamed = await fs.rename(created, 'Ünïcode & spaces');
      expect(p.basename(renamed), 'Ünïcode & spaces.md');
    });

    test('folders with spaces nest correctly', () async {
      final folder = await fs.createFolder(tempRoot.path, 'My Meeting Notes');
      final file = await fs.createFile(folder, 'Q3 Planning');
      expect(await File(file).exists(), isTrue);
      expect(p.isWithin(folder, file), isTrue);
    });
  });

  group('move: nested, conflict, noop, invalid', () {
    test('moves a file into a nested folder', () async {
      final src = p.join(tempRoot.path, 'note.md');
      await File(src).writeAsString('x');
      final destDir = p.join(tempRoot.path, 'a', 'b');
      await Directory(destDir).create(recursive: true);

      final moved = await fs.move(src, destDir);
      expect(await File(moved).exists(), isTrue);
      expect(await File(src).exists(), isFalse);
      expect(p.dirname(moved), destDir);
    });

    test(
      'move into current parent is a noop; into own descendant is invalid',
      () async {
        final folder = p.join(tempRoot.path, 'folder');
        final sub = p.join(folder, 'sub');
        await Directory(sub).create(recursive: true);
        final explorer = ExplorerController();
        await explorer.setRoot(tempRoot.path);

        expect(
          (await explorer.move(sub, destDir: folder)).status,
          MoveStatus.noop,
        );
        expect(
          (await explorer.move(folder, destDir: sub)).status,
          MoveStatus.invalid,
        );
      },
    );

    test('collision on move surfaces MoveStatus.collision', () async {
      final src = p.join(tempRoot.path, 'x.md');
      final destDir = p.join(tempRoot.path, 'dest');
      await File(src).writeAsString('1');
      await Directory(destDir).create();
      await File(p.join(destDir, 'x.md')).writeAsString('2');
      final explorer = ExplorerController();
      await explorer.setRoot(tempRoot.path);

      final res = await explorer.move(src, destDir: destDir);
      expect(res.status, MoveStatus.collision);
      // replace:true resolves it.
      final replaced = await explorer.move(
        src,
        destDir: destDir,
        replace: true,
      );
      expect(replaced.status, MoveStatus.moved);
    });
  });

  group('line-ending preservation', () {
    test('a CRLF file stays CRLF after editing and saving', () async {
      final path = p.join(tempRoot.path, 'win.md');
      await File(path).writeAsString('# Title\r\nBody\r\n');

      final editor = EditorController();
      await editor.open(path);
      expect(editor.text.text.contains('\r'), isFalse); // LF in memory
      await editor.setContent('# Title\nBody\nMore');
      editor.dispose();

      final onDisk = await File(path).readAsString();
      expect(onDisk.contains('\r\n'), isTrue);
      expect(onDisk, '# Title\r\nBody\r\nMore');
    });

    test('an LF file stays LF after saving', () async {
      final path = p.join(tempRoot.path, 'unix.md');
      await File(path).writeAsString('# Title\nBody\n');

      final editor = EditorController();
      await editor.open(path);
      await editor.setContent('# Title\nBody\nMore');
      editor.dispose();

      final onDisk = await File(path).readAsString();
      expect(onDisk.contains('\r'), isFalse);
    });
  });

  group('FileWatcherService', () {
    test('NoopFileWatcherService never fires and cancels cleanly', () async {
      var fired = false;
      final handle = const NoopFileWatcherService().watch(
        tempRoot.path,
        () => fired = true,
      );
      await File(p.join(tempRoot.path, 'x.md')).writeAsString('x');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fired, isFalse);
      handle.cancel();
      handle.cancel(); // idempotent
    });

    test('IoFileWatcherService fires on an external change', () async {
      final done = Completer<void>();
      final handle = const IoFileWatcherService().watch(tempRoot.path, () {
        if (!done.isCompleted) done.complete();
      }, debounce: const Duration(milliseconds: 50));
      // Give the OS watch a moment to arm, then make a change.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await File(p.join(tempRoot.path, 'external.md')).writeAsString('hi');

      await done.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () =>
            fail('watcher did not report the external change in time'),
      );
      handle.cancel();
    });
  });
}
