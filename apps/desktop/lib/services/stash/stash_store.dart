// Persists the last-opened Stash (name + path) so the workspace restores on next launch.
//
// This stores only the *pointer* to the Stash folder — never note content. The filesystem
// remains the source of truth for notes, preserving the local-first model.

import 'package:shared_preferences/shared_preferences.dart';

class StashConfig {
  const StashConfig({required this.name, required this.path});
  final String name;
  final String path;
}

class StashStore {
  static const _kName = 'notely.stash.name';
  static const _kPath = 'notely.stash.path';

  Future<StashConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_kName);
    final path = prefs.getString(_kPath);
    if (name == null || path == null) return null;
    return StashConfig(name: name, path: path);
  }

  Future<void> save(StashConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kName, config.name);
    await prefs.setString(_kPath, config.path);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kName);
    await prefs.remove(_kPath);
  }
}
