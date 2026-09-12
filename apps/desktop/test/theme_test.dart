// Tests for theme persistence + the token system covering both brightnesses.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/app/theme.dart';
import 'package:notely_desktop/app/theme_controller.dart';
import 'package:notely_desktop/services/settings/theme_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('ThemeStore round-trips the mode', () async {
    final store = ThemeStore();
    expect(await store.load(), isNull);
    await store.save(ThemeMode.light);
    expect(await store.load(), ThemeMode.light);
    await store.save(ThemeMode.system);
    expect(await store.load(), ThemeMode.system);
  });

  test('ThemeController defaults to dark and persists changes', () async {
    final store = ThemeStore();
    final c = ThemeController(store: store);
    expect(c.mode, ThemeMode.dark);

    await c.setMode(ThemeMode.light);
    expect(c.mode, ThemeMode.light);
    expect(await store.load(), ThemeMode.light);

    // A fresh controller restores the persisted choice.
    final restored = ThemeController(store: store);
    await restored.restore();
    expect(restored.mode, ThemeMode.light);
  });

  test('ThemeController cycles dark → light → system → dark', () async {
    final c = ThemeController(store: ThemeStore());
    expect(c.mode, ThemeMode.dark);
    await c.cycle();
    expect(c.mode, ThemeMode.light);
    await c.cycle();
    expect(c.mode, ThemeMode.system);
    await c.cycle();
    expect(c.mode, ThemeMode.dark);
  });

  test('both themes expose NotelyTokens with distinct surfaces', () {
    for (final brightness in Brightness.values) {
      final theme = buildNotelyTheme(brightness);
      final tokens = theme.extension<NotelyTokens>();
      expect(tokens, isNotNull, reason: '$brightness must carry tokens');
      // Layered surfaces are not identical (background vs elevated).
      expect(tokens!.background, isNot(tokens.raised));
      expect(tokens.speakers, isNotEmpty);
    }
  });

  test('token lerp interpolates between themes', () {
    final mid = NotelyTokens.dark.lerp(NotelyTokens.light, 0.5);
    expect(mid.speakers.length, NotelyTokens.dark.speakers.length);
    // Midpoint accent differs from both endpoints.
    expect(mid.accent, isNot(NotelyTokens.dark.accent));
    expect(mid.accent, isNot(NotelyTokens.light.accent));
  });
}
