// Stash (vault) selection state.
//
// A Stash is a folder on disk holding Notely's markdown notes — the Obsidian "vault" concept.
// For the mockup this controller only tracks which stash is "open"; no filesystem access
// happens. Later, opening a stash will ask the engine to index the folder.

import 'package:flutter/foundation.dart';

/// Tracks the currently open stash. Null until the user opens one via the picker.
class StashController extends ChangeNotifier {
  String? _name;
  String? _path;

  String? get name => _name;
  String? get path => _path;
  bool get isOpen => _name != null;

  /// Default values presented in the picker.
  static const String defaultPath = '~/Documents/Notely/Work';
  static const String defaultName = 'Work';

  /// Open a stash. In the real app this would trigger engine-side indexing.
  void open({required String name, required String path}) {
    _name = name;
    _path = path;
    notifyListeners();
  }

  /// Return to the picker (e.g. "Switch Stash").
  void close() {
    _name = null;
    _path = null;
    notifyListeners();
  }
}
