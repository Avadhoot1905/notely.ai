---
name: desktop
description: Load when working on desktop lifecycle, native integration, or cross-platform behavior — the "same product, native underneath" rule, the service seams for OS specifics, the 10 notely/* platform channels, background runtime, and per-OS caveats.
---

# desktop

## Principle
**Same product behavior, native implementation underneath.** UI and domain code never branch on the
OS. Targets: **macOS, Windows, Linux** (one product, one UI). See `docs/cross-platform.md`,
`docs/meeting-companion.md`.

## Where OS-specific code is allowed (never in UI widgets)
| Concern | Neutral surface | Native detail |
|---|---|---|
| File ops / reveal / open-external | `FileSystemService` | `open`/`explorer`/`gdbus`+`xdg-open` |
| External-change watching | `FileWatcherService` | FSEvents / ReadDirectoryChangesW / inotify |
| Home / default folder | `PathService` | `$HOME` / `%USERPROFILE%` |
| Audio capture + capabilities | `MeetingAudioService` | `record` pkg (mic); system audio = gap |
| File-manager name, ⌘/Ctrl hints | `PlatformUi` / `platform_ui.dart` | `defaultTargetPlatform` |
| Folder picker | `file_selector` | `file_selector_{macos,windows,linux}` |

## Native meeting/companion runtime — 10 `notely/*` channels
The same 10 channels exist in all four implementations (`macos/Runner/MainFlutterWindow.swift`,
`windows/runner/notely_runtime.cpp`, `linux/runner/notely_runtime.cc`, + Dart): `notely/capabilities`,
`/window`, `/notifications`(+`/actions`), `/meeting_detector`(+`/events`), `/companion`(+`/commands`),
`/companion/incoming`, `/companion/outgoing`. **Change a channel name or payload key on one platform →
change it on all four** (contract stability is verified statically).

## Filesystem semantics (get these right)
- Case-only renames (`notes.md`→`Notes.md`) go via a temp name (case-insensitive FS safety).
- Line endings: LF in memory; original LF/CRLF remembered on open and restored on save.
- Markdown image links always use `/`. Unicode/spaces in names supported. Paths via `package:path`.

## Background lifecycle
macOS keeps the process alive after the main window closes
(`applicationShouldTerminateAfterLastWindowClosed = false`; reopen re-shows). **Windows/Linux have no
tray for relaunch yet** — a documented gap; the process stays alive but there's no reopen affordance.

## Platform verification reality
macOS is build/test/launch-verified here. **Windows/Linux native adapters are compile-gated by CI
only and not runtime-QA'd.** Don't claim verified Windows/Linux GUI behavior. See compatibility-matrix.

## Related skills
overlay · flutter-ui · ipc · compatibility-matrix · release-engineering · audio
