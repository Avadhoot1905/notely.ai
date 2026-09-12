// Persists the last-opened Stash and a short list of recent Stashes.
//
// Only the *pointers* to Stash folders are stored (name + path) — never note content. The
// filesystem stays the source of truth for notes, preserving the local-first model. Recents
// power the bottom Stash switcher.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class StashConfig {
  const StashConfig({required this.name, required this.path});
  final String name;
  final String path;

  Map<String, String> toJson() => {'name': name, 'path': path};

  static StashConfig? fromJson(Object? json) {
    if (json is Map && json['name'] is String && json['path'] is String) {
      return StashConfig(
        name: json['name'] as String,
        path: json['path'] as String,
      );
    }
    return null;
  }
}

class StashStore {
  static const _kName = 'notely.stash.name';
  static const _kPath = 'notely.stash.path';
  static const _kRecents = 'notely.stash.recents';

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

  Future<List<StashConfig>> loadRecents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRecents);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(StashConfig.fromJson)
          .whereType<StashConfig>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveRecents(List<StashConfig> recents) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kRecents,
      jsonEncode(recents.map((c) => c.toJson()).toList()),
    );
  }
}
