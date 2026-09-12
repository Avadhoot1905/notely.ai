// Owns the active [ThemeMode] and persists changes.
//
// Dark is the reference/default. The choice is restored at startup and saved whenever it
// changes, so it survives restarts.

import 'package:flutter/material.dart';

import '../services/settings/theme_store.dart';

class ThemeController extends ChangeNotifier {
  ThemeController({ThemeStore? store}) : _store = store ?? ThemeStore();

  final ThemeStore _store;
  ThemeMode _mode = ThemeMode.dark;

  ThemeMode get mode => _mode;

  /// Restore the persisted mode (falls back to the default if none saved).
  Future<void> restore() async {
    final saved = await _store.load();
    if (saved != null && saved != _mode) {
      _mode = saved;
      notifyListeners();
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    await _store.save(mode);
  }

  /// Cycle dark → light → system for the compact toggle.
  Future<void> cycle() {
    final next = switch (_mode) {
      ThemeMode.dark => ThemeMode.light,
      ThemeMode.light => ThemeMode.system,
      ThemeMode.system => ThemeMode.dark,
    };
    return setMode(next);
  }
}
