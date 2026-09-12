// Cross-platform behaviour tests: platform-aware UI labels/hints, LF newline normalization on
// read, and graceful handling of a stash folder that no longer exists.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/features/editor/editor_state.dart';
import 'package:notely_desktop/features/stash/stash_state.dart';
import 'package:notely_desktop/platform/platform_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('PlatformUi labels/hints read natively per OS', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('macOS: Finder + ⌘ hints', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(PlatformUi.fileManagerName, 'Finder');
      expect(PlatformUi.revealLabel, 'Reveal in Finder');
      expect(PlatformUi.shortcutHint('I', shift: true), '⇧⌘I');
    });

    test('Windows: File Explorer + Ctrl hints', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(PlatformUi.fileManagerName, 'File Explorer');
      expect(PlatformUi.revealLabel, 'Reveal in File Explorer');
      expect(PlatformUi.shortcutHint('I', shift: true), 'Ctrl+Shift+I');
    });

    test('Linux: generic file manager', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(PlatformUi.revealLabel, 'Reveal in File Manager');
      expect(PlatformUi.shortcutHint('N'), 'Ctrl+N');
    });
  });

  test('editor normalizes CRLF/CR to LF on open', () async {
    final dir = await Directory.systemTemp.createTemp('notely_eol_');
    final path = p.join(dir.path, 'Note.md');
    // A Windows-authored file with CRLF line endings.
    await File(path).writeAsString('# Title\r\nBody line\r\nMore\r');

    final editor = EditorController();
    await editor.open(path);
    expect(editor.text.text.contains('\r'), isFalse);
    expect(editor.text.text, '# Title\nBody line\nMore\n');

    editor.dispose();
    await dir.delete(recursive: true);
  });

  test(
    'opening a missing stash folder surfaces an error, not a broken workspace',
    () async {
      SharedPreferences.setMockInitialValues({});
      final c = StashController();
      await c.open(
        name: 'Gone',
        path: p.join(Directory.systemTemp.path, 'nope_notely_missing_xyz'),
      );

      expect(c.isOpen, isFalse);
      expect(c.error, isNotNull);

      c.clearError();
      expect(c.error, isNull);
      c.dispose();
    },
  );
}
