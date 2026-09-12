// Platform-neutral path helpers.
//
// Keeps OS knowledge (home-directory env vars, per-OS conventions) out of the UI: widgets ask
// for "a sensible default location" rather than reading `Platform.environment` themselves. The
// home directory is `$HOME` on macOS/Linux and `%USERPROFILE%` on Windows.

import 'dart:io';

import 'package:path/path.dart' as p;

class PathService {
  const PathService();

  /// The current user's home directory, or null if it can't be determined.
  String? homeDirectory() =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  /// A sensible default parent folder to create/open a Stash under — the user's Documents folder
  /// when a home directory is known, otherwise null (the picker then starts at the OS default).
  String? defaultStashParent() {
    final home = homeDirectory();
    return home == null ? null : p.join(home, 'Documents');
  }
}
