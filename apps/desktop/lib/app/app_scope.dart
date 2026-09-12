// App-wide controller scope.
//
// A tiny InheritedWidget that exposes the feature controllers to the widget tree without a
// third-party state-management dependency. Widgets read them via `AppScope.of(context)` and
// rebuild by wrapping the relevant controller in a ListenableBuilder/AnimatedBuilder.

import 'package:flutter/widgets.dart';

import '../features/editor/editor_state.dart';
import '../features/explorer/explorer_state.dart';
import '../features/listening/listening_state.dart';
import '../features/stash/stash_state.dart';
import 'theme_controller.dart';

class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.stash,
    required this.explorer,
    required this.editor,
    required this.listening,
    required this.theme,
    required super.child,
  });

  final StashController stash;
  final ExplorerController explorer;
  final EditorController editor;
  final ListeningController listening;
  final ThemeController theme;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found in widget tree');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      stash != oldWidget.stash ||
      explorer != oldWidget.explorer ||
      editor != oldWidget.editor ||
      listening != oldWidget.listening ||
      theme != oldWidget.theme;
}
