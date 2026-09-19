---
name: flutter-ui
description: Load when working on the Flutter desktop UI — the feature/controller structure, AppScope DI (no state-mgmt package), ChangeNotifier + ListenableBuilder pattern, immutable state snapshots, and the rule that features go through EngineClient, never around it.
---

# flutter-ui

## Structure (`apps/desktop/lib/`)
- `features/<feature>/` — each is UI widgets + a `*Controller extends ChangeNotifier`:
  `ask`, `editor`, `explorer`, `inbox`, `integrations`, `knowledge`, `listening`, `meetings`, `stash`.
- `services/` — platform/native seams (audio, asr, meeting, companion, filesystem, notifications,
  platform, transcript, window). UI talks to services, not to `dart:io`.
- `ipc/engine_client.dart` — the single boundary to the engine.
- `app/app_scope.dart` — DI; `app/app.dart` — runtime; `app/theme*` — theming.

## State management (no third-party package)
- Controllers extend **`ChangeNotifier`**; widgets rebuild via **`ListenableBuilder`/`AnimatedBuilder`**
  wrapping the relevant controller.
- DI is the **`AppScope` `InheritedWidget`** (`AppScope.of(context)`), which holds all controllers +
  the `EngineClient`. Add a new controller → add it to `AppScope` fields + `updateShouldNotify`.
- UI state is an **immutable snapshot** folded from an event stream (e.g. `LiveMeetingState` with a
  private `_copy`, `LiveMeetingStateController` folding `MeetingEvent`s). The UI **reads the
  projection — it must not reconstruct state from raw audio/ASR**.

## Hard rules
- **Features reach the backend only through `EngineClient`** (never around it). Widgets observe
  `EngineClient.state` for the connection indicator.
- **No pure UI widget imports `dart:io` or checks `Platform.isX`** — OS specifics live in a service or
  in `lib/platform/platform_ui.dart` (`defaultTargetPlatform`, test-overridable). See desktop.
- **Paths via `package:path`**, never string concat.
- Keyboard shortcuts define both `meta:` (macOS ⌘) and `control:` (Win/Linux) modifiers.

## Honest UI states
Permission-denied / unavailable audio and unsupported capabilities are **coherent UI states**, not
crashes (`AudioCapabilities`, `PlatformCapabilities`). Reflect real capability, don't fake features.

## Tests
Widget/state tests in `apps/desktop/test/` (e.g. `inbox/`, `knowledge/`, `theme_test.dart`,
`widget_test.dart`); integration in `integration_test/`. See testing.

## Related skills
desktop · overlay · ipc · coding-conventions · testing
