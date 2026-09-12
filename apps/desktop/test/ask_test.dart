// Tests for Ask Notely retrieval + editor citation highlighting.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/editor/editor_state.dart';
import 'package:notely_desktop/services/ask/ask_service.dart';
import 'package:path/path.dart' as p;

void main() {
  // selectLines() schedules a post-frame callback, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('notely_ask_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> write(String name, String content) async {
    final f = File(p.join(root.path, name));
    await f.create(recursive: true);
    await f.writeAsString(content);
  }

  test('retrieves passages, names files read, and cites line ranges', () async {
    await write(
      'Team Sync.md',
      '# Team Sync\n\n'
          'We agreed to move the release to Friday.\n'
          'Staging must be validated first.\n\n'
          'Unrelated paragraph about lunch.\n',
    );
    await write('Ideas.md', '# Ideas\n\nA note about gardening.\n');

    const service = MockAskService();
    final answer = await service.ask(
      query: 'When is the release?',
      stashRoot: root.path,
    );

    expect(answer.citations, isNotEmpty);
    final top = answer.citations.first;
    expect(p.basename(top.path), 'Team Sync.md');
    // The matched passage covers the "release" lines (not the lunch paragraph).
    expect(top.snippet.toLowerCase(), contains('release'));
    expect(top.startLine, greaterThanOrEqualTo(0));
    expect(top.endLine, greaterThanOrEqualTo(top.startLine));
    // Files-read lists the note the answer drew from.
    expect(answer.filesRead, contains(top.path));
    // Answer references the citation with a [1] marker.
    expect(answer.text, contains('[1]'));
  });

  test('empty result when nothing matches', () async {
    await write('Ideas.md', '# Ideas\n\nGardening tips.\n');
    const service = MockAskService();
    final answer = await service.ask(
      query: 'quantum chromodynamics',
      stashRoot: root.path,
    );
    expect(answer.citations, isEmpty);
    expect(answer.filesRead, isEmpty);
  });

  test('editor.selectLines highlights the cited line range', () async {
    final path = p.join(root.path, 'Note.md');
    // Lines (0-based): 0:"# Note", 1:"", 2:"alpha", 3:"beta", 4:"gamma"
    await write('Note.md', '# Note\n\nalpha\nbeta\ngamma\n');
    final editor = EditorController();
    await editor.open(path);

    editor.selectLines(2, 3); // "alpha\nbeta"
    final sel = editor.text.selection;
    expect(editor.text.text.substring(sel.start, sel.end), 'alpha\nbeta');
    editor.dispose();
  });
}
