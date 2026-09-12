// Stash (vault) selection state.
//
// A Stash is a real folder on disk holding the user's Markdown notes — the Obsidian "vault"
// concept. This controller tracks the open Stash and persists it (name + path only) via
// [StashStore] so it restores on next launch. The filesystem stays authoritative for notes.

import 'package:flutter/foundation.dart';

import '../../services/stash/stash_store.dart';

class StashController extends ChangeNotifier {
  StashController({StashStore? store}) : _store = store ?? StashStore();

  final StashStore _store;

  String? _name;
  String? _path;
  bool _restoring = true;

  String? get name => _name;
  String? get path => _path;
  bool get isOpen => _name != null && _path != null;

  /// True while the initial restore-from-disk is in flight (avoids flashing the picker).
  bool get isRestoring => _restoring;

  /// Attempt to restore the previously opened Stash. Called once at startup.
  Future<void> restore() async {
    try {
      final config = await _store.load();
      if (config != null) {
        _name = config.name;
        _path = config.path;
      }
    } catch (_) {
      // Ignore corrupt/unavailable prefs; user will re-pick.
    } finally {
      _restoring = false;
      notifyListeners();
    }
  }

  /// Open a stash and persist it as the last-used one.
  Future<void> open({required String name, required String path}) async {
    _name = name;
    _path = path;
    notifyListeners();
    try {
      await _store.save(StashConfig(name: name, path: path));
    } catch (_) {
      // Non-fatal: the stash is usable this session even if persistence fails.
    }
  }

  /// Return to the picker ("Switch Stash") and forget the persisted stash.
  Future<void> close() async {
    _name = null;
    _path = null;
    notifyListeners();
    try {
      await _store.clear();
    } catch (_) {}
  }
}
