# apps/desktop — Flutter desktop app

All UI, navigation, and user interaction for Notely (macOS/Windows/Linux). It talks to the engine
**only** over IPC and contains **no** media/ASR/AI/model/storage/orchestration logic.

## Structure (`lib/`)
- `app/` — `app.dart` (runtime), `app_scope.dart` (DI), `theme*`.
- `ipc/` — `protocol.dart` + `engine_client.dart`: the mirror of the Rust IPC contract (`protocolVersion=4`).
- `features/<feature>/` — UI widgets + a `*Controller extends ChangeNotifier` (ask, editor, explorer,
  inbox, integrations, knowledge, listening, meetings, stash).
- `services/` — platform/native seams and non-UI logic → see `lib/services/CLAUDE.md`.
- `companion/companion_main.dart` — second Flutter engine entrypoint for the overlay (presentation-only).

## Boundaries (don't bypass)
- **Features reach the backend only through `EngineClient`** (the IPC boundary) — never around it.
  Widgets observe `EngineClient.state` for the connection indicator.
- **UI never branches on the OS.** No pure UI widget imports `dart:io` or checks `Platform.isX`;
  OS-specific behavior lives behind a service in `lib/services/` or a helper in `lib/platform/`.
- The app renders domain data received over IPC; it never reconstructs backend state locally.

## Local conventions
- **State:** `ChangeNotifier` controllers + `ListenableBuilder`/`AnimatedBuilder`. **No third-party
  state-management package.** DI is the `AppScope` `InheritedWidget` (`AppScope.of(context)`); add a
  controller → add it to `AppScope` fields + `updateShouldNotify`.
- UI state is an **immutable snapshot folded from an event stream** — read the projection, don't rebuild
  it from raw inputs (e.g. `LiveMeetingState`).
- Paths via `package:path` (never string concat). Shortcuts define both `meta:` (⌘) and `control:`.
- Capabilities are **honest UI states**: permission-denied/unsupported (audio, platform) are coherent
  states via `AudioCapabilities` / `PlatformCapabilities`, not crashes and not faked features.

## Important files
`lib/app/app_scope.dart` · `lib/ipc/engine_client.dart` · `lib/ipc/protocol.dart` ·
`lib/features/meetings/meeting_session_manager.dart` (single meeting-state owner).

## Testing
```bash
cd apps/desktop && flutter pub get
dart format lib test integration_test && flutter analyze
flutter test                 # unit/widget/state (test/)
flutter test integration_test
```
Key suites: `test/ipc/` (mirror the Rust protocol), `test/audio/`, `test/meeting_*`, `test/inbox/`,
`test/knowledge/`, `test/cross_platform_fs_test.dart`, `test/platform*`.

## Generated files — do not hand-edit
`.dart_tool/`, `build/`, platform runner build outputs. `pubspec.lock` (update via `flutter pub`).
Native runner files under `macos/`, `windows/`, `linux/` are real source (see `lib/services/CLAUDE.md`),
not generated — but changing a `notely/*` channel there means changing all four platforms.

## Platform reality
macOS is build/test/launch-verified. **Windows/Linux native adapters are compile-gated by CI only and
not runtime-QA'd** — don't claim verified Windows/Linux GUI behavior.

## Related skills
flutter-ui · desktop · overlay · ipc · testing · coding-conventions

## Related modules
`lib/services/CLAUDE.md` · `packages/protocol/CLAUDE.md` · `engine/CLAUDE.md`
