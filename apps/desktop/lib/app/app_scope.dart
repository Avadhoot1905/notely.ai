// App-wide controller scope.
//
// A tiny InheritedWidget that exposes the feature controllers to the widget tree without a
// third-party state-management dependency. Widgets read them via `AppScope.of(context)` and
// rebuild by wrapping the relevant controller in a ListenableBuilder/AnimatedBuilder.

import 'package:flutter/widgets.dart';

import '../features/ask/ask_state.dart';
import '../features/editor/editor_state.dart';
import '../features/explorer/explorer_state.dart';
import '../features/inbox/inbox_state.dart';
import '../features/integrations/integrations_state.dart';
import '../features/knowledge/knowledge_state.dart';
import '../features/listening/listening_state.dart';
import '../features/meetings/meeting_session_manager.dart';
import '../features/stash/stash_state.dart';
import '../ipc/engine_client.dart';
import 'theme_controller.dart';

class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.stash,
    required this.explorer,
    required this.editor,
    required this.listening,
    required this.theme,
    required this.ask,
    required this.inbox,
    required this.meetings,
    required this.knowledge,
    required this.integrations,
    required this.engine,
    required super.child,
  });

  final StashController stash;
  final ExplorerController explorer;
  final EditorController editor;
  final ListeningController listening;
  final ThemeController theme;
  final AskController ask;
  final InboxController inbox;
  final MeetingSessionManager meetings;

  /// The Knowledge Space (semantic-topographic view of the vault).
  final KnowledgeController knowledge;

  /// External knowledge sources (Slack/Teams) connection + import state.
  final IntegrationsController integrations;

  /// The single IPC boundary to the Rust engine. Widgets observe [EngineClient.state] for the
  /// connection indicator; features go through it (never around it) to reach the backend.
  final EngineClient engine;

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
      theme != oldWidget.theme ||
      ask != oldWidget.ask ||
      inbox != oldWidget.inbox ||
      meetings != oldWidget.meetings ||
      knowledge != oldWidget.knowledge ||
      integrations != oldWidget.integrations ||
      engine != oldWidget.engine;
}
