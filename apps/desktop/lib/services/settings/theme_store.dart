// Persists the selected theme mode (system/light/dark) via shared_preferences.
//
// Only a single enum value is stored; this reuses the same lightweight preferences mechanism
// as the Stash pointer (no new persistence layer).

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeStore {
  static const _key = 'notely.theme.mode';

  Future<ThemeMode?> load() async {
    final prefs = await SharedPreferences.getInstance();
    switch (prefs.getString(_key)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
      default:
        return null;
    }
  }

  Future<void> save(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}
