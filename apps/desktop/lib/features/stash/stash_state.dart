// Stash (vault) selection state.
//
// A Stash is a real folder on disk holding the user's Markdown notes — the Obsidian "vault"
// concept. This controller tracks the open Stash, a list of recent Stashes (for the switcher),
// and whether the picker is being shown *over* an already-open stash (so switching can be
// cancelled). Persistence stores only name + path — the filesystem stays authoritative.

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../services/filesystem/file_system_service.dart';
import '../../services/stash/stash_store.dart';

class StashController extends ChangeNotifier {
  StashController({StashStore? store, FileSystemService? fs})
    : _store = store ?? StashStore(),
      _fs = fs ?? const FileSystemService();

  final StashStore _store;
  final FileSystemService _fs;

  static const int _maxRecents = 8;

  String? _name;
  String? _path;
  bool _restoring = true;
  bool _pickerRequested = false;
  List<StashConfig> _recents = const [];
  String? _error;

  String? get name => _name;
  String? get path => _path;
  bool get isOpen => _name != null && _path != null;

  /// A user-facing problem opening a stash (e.g. the folder no longer exists / is inaccessible),
  /// surfaced in the picker. Cleared on the next successful action.
  String? get error => _error;

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// True while the initial restore-from-disk is in flight (avoids flashing the picker).
  bool get isRestoring => _restoring;

  /// Recently opened stashes, most-recent first (used by the switcher).
  List<StashConfig> get recents => _recents;

  /// The picker should be shown when no stash is open, or when explicitly requested to switch.
  bool get showPicker => !isOpen || _pickerRequested;

  /// The picker can be dismissed (closed) only when there's an open stash to return to.
  bool get canDismissPicker => isOpen;

  /// Load the list of recent stashes at startup. Deliberately does NOT auto-open the last
  /// stash — the launch screen is always the picker, which lists these recents so the user
  /// chooses which stash to enter (or creates/opens a new one).
  Future<void> restore() async {
    try {
      _recents = await _store.loadRecents();
    } catch (_) {
      // Ignore corrupt/unavailable prefs; the picker still shows.
    } finally {
      _restoring = false;
      notifyListeners();
    }
  }

  /// Open a stash and persist it as the last-used one (and prepend it to recents). Validates the
  /// folder still exists first — a recent stash may point at a deleted folder or a disconnected
  /// drive (common on Windows) — surfacing [error] and keeping the picker up instead of entering
  /// a broken workspace.
  Future<void> open({required String name, required String path}) async {
    if (!await _fs.exists(path)) {
      _error =
          'This stash folder could not be found. It may have been moved, '
          'deleted, or is on a drive that isn’t connected.';
      notifyListeners();
      return;
    }
    _error = null;
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

  /// Create a new stash folder named [name] under [parentPath] and open it. Returns its path,
  /// or null on failure. If the folder already exists it is opened as-is.
  Future<String?> createStash({
    required String parentPath,
    required String name,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final path = p.join(parentPath, trimmed);
    try {
      if (!await _fs.exists(path)) {
        await _fs.createFolder(parentPath, trimmed);
      }
      await open(name: trimmed, path: path);
      return path;
    } catch (_) {
      return null;
    }
  }

  /// Remove a stash from the recents list (does not touch the folder on disk).
  Future<void> removeRecent(String path) async {
    _recents = _recents.where((c) => !p.equals(c.path, path)).toList();
    notifyListeners();
    try {
      await _store.saveRecents(_recents);
    } catch (_) {}
  }

  List<StashConfig> _mergeRecent(StashConfig config) {
    // Dedupe with path-aware equality so Windows' case-insensitive paths ("C:\X" vs "c:\x")
    // don't create duplicate recents entries.
    final next = [
      config,
      ..._recents.where((c) => !p.equals(c.path, config.path)),
    ];
    return next.take(_maxRecents).toList();
  }
}
