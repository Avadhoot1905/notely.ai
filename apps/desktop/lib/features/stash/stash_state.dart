// Stash (vault) selection state.
//
// A Stash is a real folder on disk holding the user's Markdown notes — the Obsidian "vault"
// concept. This controller tracks the open Stash, a list of recent Stashes (for the switcher),
// and whether the picker is being shown *over* an already-open stash (so switching can be
// cancelled). Persistence stores only name + path — the filesystem stays authoritative.

import 'package:flutter/foundation.dart';

import '../../services/stash/stash_store.dart';

class StashController extends ChangeNotifier {
  StashController({StashStore? store}) : _store = store ?? StashStore();

  final StashStore _store;

  static const int _maxRecents = 8;

  String? _name;
  String? _path;
  bool _restoring = true;
  bool _pickerRequested = false;
  List<StashConfig> _recents = const [];

  String? get name => _name;
  String? get path => _path;
  bool get isOpen => _name != null && _path != null;

  /// True while the initial restore-from-disk is in flight (avoids flashing the picker).
  bool get isRestoring => _restoring;

  /// Recently opened stashes, most-recent first (used by the switcher).
  List<StashConfig> get recents => _recents;

  /// The picker should be shown when no stash is open, or when explicitly requested to switch.
  bool get showPicker => !isOpen || _pickerRequested;

  /// The picker can be dismissed (closed) only when there's an open stash to return to.
  bool get canDismissPicker => isOpen;

  /// Attempt to restore the previously opened Stash + recents. Called once at startup.
  Future<void> restore() async {
    try {
      _recents = await _store.loadRecents();
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

  /// Open a stash and persist it as the last-used one (and prepend it to recents).
  Future<void> open({required String name, required String path}) async {
    _name = name;
    _path = path;
    _pickerRequested = false;
    _recents = _mergeRecent(StashConfig(name: name, path: path));
    notifyListeners();
    try {
      await _store.save(StashConfig(name: name, path: path));
      await _store.saveRecents(_recents);
    } catch (_) {
      // Non-fatal: the stash is usable this session even if persistence fails.
    }
  }

  /// Ask to show the picker over the current workspace so the user can switch stashes.
  void requestPicker() {
    if (_pickerRequested) return;
    _pickerRequested = true;
    notifyListeners();
  }

  /// Cancel switching and return to the current workspace (only meaningful when a stash is open).
  void dismissPicker() {
    if (!_pickerRequested) return;
    _pickerRequested = false;
    notifyListeners();
  }

  List<StashConfig> _mergeRecent(StashConfig config) {
    final next = [config, ..._recents.where((c) => c.path != config.path)];
    return next.take(_maxRecents).toList();
  }
}
