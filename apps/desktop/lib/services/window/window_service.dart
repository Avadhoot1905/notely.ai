// Main-window control abstraction.
//
// Small seam for the few things the app needs to do to its OWN main window from Dart — today just
// "bring me to the front" (used when the user picks "Open in Notely" from the companion). Native
// runners implement `notely/window`; platforms without it degrade to a no-op.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract class WindowService {
  /// Show + focus the main Notely window (deminiaturize/unhide as needed).
  Future<void> focusMain();
}

class PlatformWindowService implements WindowService {
  const PlatformWindowService();

  static const _channel = MethodChannel('notely/window');

  @override
  Future<void> focusMain() async {
    try {
      await _channel.invokeMethod('focus');
    } on MissingPluginException {
      // No native handler on this platform — nothing to do.
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('WindowService.focus failed: ${e.message}');
    }
  }
}

class NoopWindowService implements WindowService {
  const NoopWindowService();
  @override
  Future<void> focusMain() async {}
}
