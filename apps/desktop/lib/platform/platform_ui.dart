// Platform-aware presentation helpers.
//
// The UI stays platform-neutral: instead of hard-coding macOS terminology ("Finder", "⌘"),
// widgets ask here for the label/hint that reads natively on the current OS. The *behaviour*
// (reveal a file, insert an image) is identical everywhere — only the wording differs.
//
// Uses [defaultTargetPlatform] rather than dart:io's `Platform`, so it works without dart:io and
// is overridable in widget tests via `debugDefaultTargetPlatformOverride`. Platform-specific
// *implementations* (Process invocations, entitlements) live in the service layer, not here.

import 'package:flutter/foundation.dart';

abstract final class PlatformUi {
  static bool get isMacOS => defaultTargetPlatform == TargetPlatform.macOS;
  static bool get isWindows => defaultTargetPlatform == TargetPlatform.windows;

  /// The OS file manager's name, for inline copy ("Opens in Finder").
  static String get fileManagerName => isMacOS
      ? 'Finder'
      : isWindows
      ? 'File Explorer'
      : 'file manager';

  /// Label for the "reveal a file in the OS file manager" action. Keeps the verb consistent
  /// while naming the native app: Finder / File Explorer / (generic) File Manager.
  static String get revealLabel => isMacOS
      ? 'Reveal in Finder'
      : isWindows
      ? 'Reveal in File Explorer'
      : 'Reveal in File Manager';

  /// A keyboard-shortcut hint that reads natively: "⇧⌘I" on macOS, "Ctrl+Shift+I" elsewhere.
  /// [primary] is the command modifier (⌘ on macOS, Ctrl otherwise).
  static String shortcutHint(
    String key, {
    bool shift = false,
    bool primary = true,
  }) {
    if (isMacOS) {
      return '${shift ? '⇧' : ''}${primary ? '⌘' : ''}$key';
    }
    return [if (primary) 'Ctrl', if (shift) 'Shift', key].join('+');
  }
}
