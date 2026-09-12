// Tests for image retention: importing into the stash + inserting a Markdown link.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/editor/editor_state.dart';
import 'package:notely_desktop/features/explorer/explorer_state.dart';
import 'package:notely_desktop/services/filesystem/file_system_service.dart';
import 'package:notely_desktop/services/filesystem/fs_node.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory sourceDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('notely_img_');
    sourceDir = await Directory.systemTemp.createTemp('notely_img_src_');
  });
  tearDown(() async {
    for (final d in [root, sourceDir]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  Future<String> makeImage(String name) async {
    final path = p.join(sourceDir.path, name);
    await File(path).writeAsBytes([0x89, 0x50, 0x4E, 0x47]); // fake PNG header
    return path;
  }

  test('FsNode recognises image extensions', () {
    expect(FsNode(path: '/x/a.png', isDirectory: false).isImage, isTrue);
    expect(FsNode(path: '/x/a.JPG', isDirectory: false).isImage, isTrue);
    expect(FsNode(path: '/x/a.md', isDirectory: false).isImage, isFalse);
    expect(FsNode(path: '/x/dir', isDirectory: true).isImage, isFalse);
  });

  test('importImage copies into attachments/ and de-duplicates', () async {
    const fs = FileSystemService();
    final src = await makeImage('diagram.png');

    final dest1 = await fs.importImage(root.path, src);
    expect(await File(dest1).exists(), isTrue);
    expect(p.basename(dest1), 'diagram.png');
    expect(p.basename(p.dirname(dest1)), 'attachments');

    // Importing the same name again must not overwrite.
    final dest2 = await fs.importImage(root.path, src);
    expect(dest2, isNot(dest1));
    expect(await File(dest1).exists(), isTrue);
    expect(await File(dest2).exists(), isTrue);
  });

  test('imported images appear in the explorer tree', () async {
    final explorer = ExplorerController();
    await explorer.setRoot(root.path);
    final src = await makeImage('shot.png');

    final dest = await explorer.importImage(src);
    expect(dest, isNotNull);

    final attachments = explorer.roots.firstWhere(
      (n) => n.isDirectory && n.name == 'attachments',
    );
    expect(attachments.children.any((n) => n.isImage), isTrue);
  });

  test('editor inserts a Markdown image link at the caret', () async {
    final path = p.join(root.path, 'Note.md');
    await File(path).writeAsString('Intro. ');
    final editor = EditorController();
    await editor.open(path);
    // Caret at end.
    editor.text.selection = const TextSelection.collapsed(offset: 7);

    editor.insertText('![shot](attachments/shot.png)');
    expect(editor.text.text, 'Intro. ![shot](attachments/shot.png)');
    expect(editor.isDirty, isTrue);

    await editor.saveNow();
    expect(
      await File(path).readAsString(),
      contains('![shot](attachments/shot.png)'),
    );
    editor.dispose();
  });
}
