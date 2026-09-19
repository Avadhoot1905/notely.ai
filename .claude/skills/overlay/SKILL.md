---
name: overlay
description: Load when working on the floating companion overlay or meeting detection. CRITICAL boundary — the overlay is a presentation-only separate native window with its own Flutter engine that renders pushed snapshots; it is NOT a second ingestion/data subsystem. Documents ownership, lifecycle, and per-OS mechanics.
---

# overlay

## What the companion overlay is
A small, always-on-top floating window that appears while a meeting is tracked, follows you across
apps, and shows the live transcript on click. Two OS features, one runtime: **meeting detection →
native OS notification**, and the **floating companion**. See `docs/meeting-companion.md`.

## Ownership & the critical boundary
- `MeetingSessionManager` (`lib/features/meetings/`) is the **single source of truth** — the state
  machine (`notRunning → awaitingDecision → tracking → finalizing`) + dedup. It's owned by the app
  runtime (`lib/app/app.dart`), decoupled from the main window (survives minimize/close).
- The companion window runs its **own Flutter engine** (`companionMain`, `lib/companion/
  companion_main.dart`) and **only renders snapshots pushed to it**. Both windows observe the *same*
  `MeetingSessionManager` — **there is no second copy of meeting state.**
- **DO NOT** give the overlay its own ingestion, ASR, storage, or IPC-to-engine path. It is
  **presentation-only**. Turning it into a second data subsystem is the primary regression to avoid here.

## Detection is honest
"App running" is **not** "in a meeting." The gate is the **microphone actually in use** + a running
conferencing app (macOS CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`; Windows WASAPI
active capture session; Linux `pactl list source-outputs`). Browser calls → reported as a **generic**
meeting (exact Google Meet detection is a documented non-goal under the macOS sandbox). Dedup by
`provider+meetingId` (or `provider+sourceApp+10-min bucket`).

## Lifecycle / resources
- The companion engine/window is **created once and reused** across show/hide — never recreated per
  meeting (that leaks engines/windows/channels). See resource-lifecycle.
- Panel hides on meeting end/stop; `MeetingSessionManager.start()` hides any leftover panel on launch
  (no stale overlay).
- **No focus stealing** (macOS `NSPanel` non-activating + floating; Windows `WS_EX_NOACTIVATE`;
  Linux non-focusing GtkWindow). Position persistence is macOS-only (UserDefaults); Win/Linux TODO.

## Platform reality
macOS verified; **Windows/Linux compile-gated only, not runtime-QA'd**. Transparency is real on macOS,
opaque-but-themed on Windows (embedder limit). Don't claim unverified interactive behavior.

## Settings
`MeetingDetectionSettings`: `notifyOnDetect` (default on), `autoStartTracking` (**default OFF** — opt-in
via notification), `showCompanion` (default on).

## Related skills
desktop · ipc · flutter-ui · concurrency · resource-lifecycle · compatibility-matrix
