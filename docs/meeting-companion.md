# Meeting detection + floating companion

Two OS-level features, one runtime:

1. **Meeting detection → native notification** — Notely notices you've joined a call (even when
   its window is closed) and asks, via a real OS notification, whether to track notes.
2. **Floating companion** — once you accept, a small always-on-top overlay appears in a **separate
   native window** and follows you across apps while it tracks; clicking it shows the live
   transcript.

## Architecture

The runtime is owned by the app process and is **decoupled from the main window** — it is not a
Flutter widget and is not gated by an open stash, so it survives the main window being
minimized/closed (the macOS app keeps running; reopening re-shows the window).

```text
Application runtime (lib/app/app.dart)
 └── MeetingSessionManager           ← single source of truth (state machine + dedup)
       ├── MeetingDetector           (notely/meeting_detector)      → native detector
       ├── NotificationService       (notely/notifications)         → native OS notification
       ├── CompanionWindowService    (notely/companion)             → native overlay window
       └── ListeningController       (existing session/transcription)
```

Both the main window and the companion window observe the **same** `MeetingSessionManager`; there
is no second copy of meeting state. The companion window runs its **own Flutter engine**
(`companionMain` in `lib/companion/companion_main.dart`) and only renders snapshots pushed to it.

State machine:

```text
notRunning ─detect─▶ awaitingDecision ─dismiss─▶ notRunning
                          │
                        start (notification / auto-track / companion)
                          ▼
                      tracking ──meeting ends / stop──▶ finalizing ──▶ notRunning
```

## Why the old implementation was broken

- **Notifications never appeared** because there was no OS notification at all — the "prompt" was
  an in-app Flutter banner (`CallNotesPrompt`) gated by `if (stash.isOpen)`, so it only showed
  when the window was open, focused, and a stash was loaded. Fixed with a real
  `UNUserNotificationCenter` path that fires regardless of window state.
- **The companion was trapped in the main window** because it was a `Positioned` widget inside the
  main window's `Stack`. Replaced with a separate, always-on-top, transparent, non-activating
  `NSPanel` hosting its own Flutter engine.

## Detection (be honest about the signal)

"App is running" is **not** treated as "in a meeting." The gate is the **microphone actually being
in use** (CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device),
combined with a running conferencing app:

| Provider | Signal (macOS) |
|---|---|
| Zoom / Teams / Discord / WhatsApp | mic in use **and** the app's bundle id is running |
| Google Meet (browser) | mic in use **and** a browser is running → reported as a **generic** meeting |

**Google Meet limitation:** under the macOS **App Sandbox**, reading a browser's tab/window title
via Accessibility is unreliable, so Notely does **not** claim to know a browser call is
specifically Google Meet — it surfaces it as a generic "meeting." Precise in-browser Meet
detection requires a browser extension (a deliberate non-goal here, documented rather than faked).

Deduplication uses `provider + meetingId`, or `provider + sourceApplication + 10-min bucket` when
no meeting id exists — so one ongoing call never produces repeated notifications, and a dismissed
meeting is never re-nagged.

## Companion window (macOS)

An `NSPanel` configured as: `.nonactivatingPanel` + `.borderless`, `level = .floating`,
`isFloatingPanel = true`, `becomesKeyOnlyIfNeeded = true`, transparent
(`isOpaque = false`, clear background, no shadow), `collectionBehavior = [.canJoinAllSpaces,
.fullScreenAuxiliary, .stationary]`, `isMovableByWindowBackground = true`.

- **No focus stealing:** non-activating + floating panel — showing it or clicking it does not
  activate Notely or take focus from the app you're working in.
- **Above other apps & across Spaces/fullscreen:** floating level + `canJoinAllSpaces` +
  `fullScreenAuxiliary`.
- **Drag + position memory:** draggable by background; position saved to `UserDefaults` and
  validated against connected displays on show (never stranded off-screen after a monitor change).
- **Click → transcript:** the companion asks native to grow the panel and shows the live
  transcript popover; "Open in Notely" brings the main window forward.
- **No stale overlay:** `MeetingSessionManager.start()` hides any leftover panel on launch; the
  panel hides on meeting end / stop.

## Settings (opt-in tracking)

`MeetingDetectionSettings` (persisted via `MeetingSettingsStore`): enabled providers,
`notifyOnDetect` (default on), `autoStartTracking` (**default OFF** — tracking is opt-in via the
notification), `showCompanion` (default on).

## Capability matrix

Legend: `✓` = implemented + verified on this host (compiles + automated tests pass; macOS app also
launches) · `⧗` = implemented, **compile-gated by CI only — not built or run by the author** ·
`~` = implemented but limited · `!` = genuine OS restriction · `✗` = not implemented. Reflected at
runtime by `PlatformCapabilities` (`lib/services/platform/platform_capabilities.dart`), sourced from
each platform's native `notely/capabilities` handler with an honest per-OS fallback.

> **No platform's *interactive* GUI behavior** (notification banner appearing, the overlay floating
> above other apps, focus non-stealing, drag, multi-monitor placement) **was manually QA'd in this
> environment.** macOS is build/test/launch-verified; Windows/Linux are compile-gated by CI only.
> The manual checklist below must be run on each target OS before calling it production-ready.

| Capability | macOS | Windows | Linux X11 | Linux Wayland |
|---|---|---|---|---|
| Meeting detection (mic + app) | ✓ | ⧗ | ⧗ | ⧗ |
| Notifications | ✓ | ⧗ | ⧗ | ⧗ |
| Notification actions | ✓ | ⧗ | ⧗ | ⧗ |
| Companion overlay | ✓ | ⧗ | ⧗ | ⧗ |
| Always-on-top | ✓ | ⧗ | ⧗ | ! compositor restricts |
| Transparency | ✓ | ~ opaque | ⧗ (RGBA) | ⧗ (RGBA) |
| Non-activating (no focus steal) | ✓ | ⧗ | ⧗ | ! varies |
| Multi-monitor | ~ | ~ | ~ | ! no absolute positioning |
| Position persistence | ~ (UserDefaults) | ✗ TODO | ✗ TODO | ✗ TODO |
| Background runtime | ✓ | ~ process stays | ~ process stays | ~ process stays |
| Tray / relaunch affordance | ~ (Dock) | ✗ TODO | ✗ TODO | ✗ TODO |
| Google Meet exact provider | ~ generic | ~ generic | ~ generic | ~ generic |

"Multi-monitor `~`" = the code validates/anchors to a visible display but interactive multi-monitor
placement is unverified. macOS uses the Dock (no separate tray needed); Windows/Linux keep the
process alive on window close but a **tray for relaunch is not yet implemented** — a real gap.

The core state machine and Dart interfaces are shared; each OS has a native adapter behind the
same `notely/*` channels (`macos/Runner/MainFlutterWindow.swift`,
`windows/runner/notely_runtime.cpp`, `linux/runner/notely_runtime.cc`). **The Windows and Linux
adapters were authored on macOS and cannot be compiled there — they are compile-gated by the new
CI build jobs (`.github/workflows/ci.yml`) and their runtime/GUI behavior is NOT yet verified.**
Each native `notely/capabilities` handler reports what that OS actually implements; if an adapter
fails to load, the Dart fallback keeps the feature honestly disabled.

## Windows native adapter (`windows/runner/notely_runtime.cpp`)

- **Detection** — WASAPI: enumerate active capture endpoints → `IAudioSessionManager2` /
  `IAudioSessionEnumerator`; a session in `AudioSessionStateActive` means the mic is in use, and the
  session's process id is mapped to a provider (Zoom/Teams/Discord/WhatsApp; browser → generic).
  Process existence alone is never a meeting. Polled every ~2 s on the UI thread via `SetTimer`.
- **Notifications** — WinRT `ToastNotificationManager` with "Start tracking"/"Dismiss" actions;
  `SetCurrentProcessExplicitAppUserModelID` sets the AUMID; the `ToastNotification::Activated` event
  routes the response back to Flutter (queued to the UI thread). No COM activator needed while running.
- **Companion** — a `WS_POPUP` window with `WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`
  (off the taskbar, never steals focus) hosting a second `FlutterViewController` on the
  `companionMain` entrypoint; rounded via `SetWindowRgn`; drag via `WM_NCLBUTTONDOWN`/`HTCAPTION`
  from a `beginDrag` command.
- **Known limitation** — the stable Flutter Windows embedder renders **opaque**, so the companion
  uses a themed background + rounded region rather than true per-pixel transparency
  (`transparentWindow = false`). Position persistence + hide-to-tray background lifecycle are TODO.

## Linux native adapter (`linux/runner/notely_runtime.cc`)

- **Detection** — `pactl list source-outputs`: a non-empty list means an app is recording from the
  mic; `application.name` is mapped to a provider (browser → generic). Polled every 2 s via
  `g_timeout_add_seconds`. Mirrors the mic-in-use rule.
- **Notifications** — `GNotification` + `g_application_send_notification` with two buttons wired to a
  single `app.notely-notif` `GAction` carrying `action|meetingKey`, routed back to Flutter.
- **Companion** — a decorated-off, keep-above, skip-taskbar, non-focusing `GtkWindow` with an RGBA
  visual for transparency, hosting a second Flutter engine. The GTK embedder has no custom-entrypoint
  API, so the companion engine runs `main(['--notely-companion'])` which dispatches to `companionMain`
  (see `lib/main.dart`). Drag via `gtk_window_begin_move_drag` from a `beginDrag` command.
- **Companion entrypoint** is the one place Linux deviates from macOS/Windows (which select the
  `companionMain` entrypoint by name) — behavior is identical, mechanism differs.

### Linux limitations (be explicit — do not fake)

- **Wayland** deliberately restricts global always-on-top and absolute window positioning; behavior
  depends on the compositor and `gtk-layer-shell` support. GNOME-on-Wayland has no app tray without
  an extension. **X11** supports the full behavior. These differences are surfaced via
  `PlatformCapabilities.notes` and must be documented, not hacked around per-compositor.

## Background lifecycle (per OS)

macOS keeps the process alive after the main window closes
(`applicationShouldTerminateAfterLastWindowClosed = false`, reopen re-shows the window). Windows and
Linux have no equivalent yet — their adapters must add a tray/hide-on-close lifecycle so detection
survives closing the window (captured as `backgroundRuntime` in the matrix).

## Manual acceptance checklist (macOS, on-device)

Detection/notification (needs signing for reliable delivery — see below):
- [ ] Join a Zoom/Teams/Meet call → OS notification "You're in a meeting" appears with Start/Dismiss
- [ ] Start tracking → companion appears, session records
- [ ] Dismiss → no companion, and the same meeting does not re-notify
- [ ] Repeated detections of one call do not spam notifications

Companion (with another app focused):
- [ ] Visible above the focused app; does not steal focus / interrupt typing
- [ ] Visible with the main window minimized and with it closed
- [ ] Draggable; position persists across restarts; not stranded after a monitor change
- [ ] Click opens the transcript popover; transcript updates live; "Open in Notely" works
- [ ] Meeting ends (mic released) → companion disappears, transcript retained for review

**Notification signing caveat:** `UNUserNotificationCenter` delivery is unreliable for unsigned dev
builds; test notifications with a signed build (a normal `flutter run` .app is usually sufficient
on the dev machine, but a signed build is the reliable path).

## Runtime-hardening audit (latest pass)

Static audit of the native adapters (no runtime access to Windows/Linux from the macOS dev host).
Findings + fixes:

- **Windows WASAPI** — confirmed detection enumerates **`eCapture` endpoints only** (render/loopback
  never included), COM interfaces are released on every path, `GetProcessId==0` (system session) is
  skipped, and one meeting is emitted per active→inactive transition (native `meeting_active_` guard +
  Dart dedup). COM is initialized on the polling (UI) thread by the runner. Re-enumerating each poll
  naturally absorbs default-device changes / disconnects.
- **Windows timestamp fix** — meeting `startedAtMs` now uses real Unix-epoch time
  (`GetSystemTimeAsFileTime`) instead of boot-relative `GetTickCount64`, so the shown start time is
  correct.
- **Windows toast hardening** — title/body/key are XML-escaped before building the toast document
  (no breakage/injection from `&`/`<`/quotes).
- **Linux process-exec hardening** — detection now uses `g_spawn_sync` with an explicit `argv`
  (`pactl list source-outputs`) instead of a parsed command line — no shell involved. `pactl` absence
  (no PulseAudio / no pipewire-pulse) degrades to "no detection", not a crash; parsing is bounded.
- **Second-engine lifecycle** — the companion engine/window is created once and **reused** across
  show/hide (not recreated per meeting), so repeated meetings don't leak engines/windows/channels.

### Remaining real gaps (not runtime-hardened)

- **Windows/Linux tray** for relaunch when the main window is closed — not implemented. The process
  stays alive (detection continues), but there's no discoverable way to reopen Notely yet.
- **Windows/Linux companion position persistence** — not implemented (defaults to a safe visible
  anchor each launch).
- **Interactive/GUI behavior on all platforms** — not manually QA'd here (see checklist).
- **Windows transparency** — opaque (embedder limit); `transparentWindow=false`, honestly reported.

## Verdict

- **macOS — READY WITH PLATFORM LIMITATIONS.** Built, unit-tested, launches; only genuine limits
  remain (Google Meet reported as a generic meeting; interactive QA still recommended before release).
- **Windows — NOT RUNTIME-VERIFIED.** Implemented and compile-gated by CI only; needs on-device QA
  plus tray + position persistence before it can be called production-ready.
- **Linux (X11/Wayland) — NOT RUNTIME-VERIFIED.** Implemented and compile-gated by CI only; needs
  on-device QA on both session types, plus tray + position persistence and confirmation of Wayland
  always-on-top behavior per compositor.

---

# Target-platform QA harness

macOS is build/test/launch-verified here; **Windows and Linux need on-device QA** before release.
This harness is written for a tester with a Windows machine and a Linux machine — no knowledge of
the native implementation required. Record results against the [release gate](#release-gate).

## Contract stability (verified statically, all platforms)

Confirmed by audit (no runtime needed): all four implementations expose the **same 10 channels**
(`notely/capabilities`, `/window`, `/notifications`(+`/actions`), `/meeting_detector`(+`/events`),
`/companion`(+`/commands`), `/companion/incoming`, `/companion/outgoing`); the 9 capability keys and
the detector/notification/companion payload keys match across macOS/Windows/Linux; companion command
strings align (macOS intentionally omits `beginDrag` — it uses native background-drag). If you change
a channel name or payload key on one platform, change it on all four.

## Build & install

```bash
# Windows (on a Windows host)
cd apps/desktop && flutter pub get && flutter build windows --release
#   → build/windows/x64/runner/Release/notely.ai.exe

# Linux (on a Linux host with: ninja-build cmake clang pkg-config libgtk-3-dev liblzma-dev)
cd apps/desktop && flutter pub get && flutter build linux --release
#   → build/linux/x64/release/bundle/notely_desktop
```

Notifications on Windows are most reliable from an **installed** build (Start-menu shortcut carrying
the AppUserModelID `ai.notely.notelyDesktop`); a bare `.exe` may not surface toasts.

## The one acceptance test (run on every platform)

```text
1. Launch Notely → 2. minimize/hide it → 3. focus another app (VS Code) and start typing →
4. join a real Zoom/Teams/Meet call → 5. OS notification "You're in a meeting" appears →
6. click "Start tracking" → 7. keep typing in the other app →
8. companion overlay is visible AND your typing app stayed focused →
9. click the companion → 10. live transcript popover → 11. close it → 12. end the call →
13. companion disappears; the session is finalized/retained for review.
```
If steps 5, 6, 8, and 12 all pass, the platform's core flow works.

## Environment to record (per run)

OS + version + arch · display scaling(s) · monitor count/arrangement · audio stack
(Windows: default mic; Linux: PulseAudio vs PipeWire, `pactl` present?) · session type
(Linux: X11 vs Wayland + compositor) · Teams/Zoom/browser versions.

## Windows checklist

- [ ] **Detection** — Teams/Zoom/Discord/WhatsApp open *without* a call → **no** detection; in a call
      (mic active) → detection with the right provider; browser call → generic. Mic active outside any
      call is intentionally treated as a generic meeting — confirm that's acceptable, don't silently change it.
- [ ] **No spam** — one meeting → exactly one notification / one session / one companion.
- [ ] **Notification** — toast appears with Notely foreground, minimized, hidden, and unfocused;
      Start tracking → tracking + companion; Dismiss → nothing; dismissed meeting doesn't re-nag.
- [ ] **Companion** — visible over VS Code / Chrome / Explorer / Terminal; **no taskbar button**
      (WS_EX_TOOLWINDOW); topmost; rounded; draggable; click opens transcript; hides on end.
- [ ] **Focus (critical)** — while typing in VS Code, trigger detection→notification→companion→
      transcript updates; keyboard focus must stay in VS Code (`GetForegroundWindow` unchanged) until
      you explicitly click the companion.
- [ ] **Stress** — start/end a meeting ≥10× → memory stable, no extra windows/engines, no stale toasts.
- [ ] **DPI** — 100/125/150/200%: correct size, hitbox, popup, no blur.
- [ ] **Multi-monitor** — single/dual/mixed-scaling/disconnect-reconnect → companion never stranded.
- [ ] **Background** — close the main window → detection continues, notification+companion still work,
      and there is a way to reopen Notely (**tray — currently a known gap**).
- [ ] **Transparency** — companion is opaque-but-intentional (rounded, themed) — expected, not a bug.

## Linux checklist (run under X11 **and** a Wayland compositor)

- [ ] **Detection** — mic inactive → none; in a call → detection; app open but no call → none;
      `pactl` present works; `pactl` absent → **no crash**, detection simply off; verify under both
      PulseAudio and PipeWire (`pipewire-pulse`).
- [ ] **Notifications** — GNOME and KDE where available; Start tracking / Dismiss actions fire (if a
      DE drops notification actions, note it — don't force an unsupported abstraction).
- [ ] **Companion — X11** — transparent, frameless, always-on-top, skip-taskbar, no focus steal,
      drag, click→transcript, multi-monitor, scaling, independent of the main window.
- [ ] **Companion — Wayland** — record what the compositor actually allows: always-on-top and absolute
      positioning are frequently restricted. Update the matrix to match reality; do **not** claim
      behavior the compositor blocks.
- [ ] **Focus** — same critical typing test as Windows.
- [ ] **Background** — close main window → detection continues; reopen path (**tray — known gap**).

## Shared runtime checks (any platform)

- [ ] **Second engine** — create/show/hide/show/hide/destroy across many meetings → no growth in
      window/engine count, memory, or duplicate callbacks (companion is created once and reused).
- [ ] **Idle cost** — no meeting: CPU/memory reasonable; detection poll is ~2 s (WASAPI / `pactl`).
- [ ] **Termination** — a brief mic blip while the provider is still active should not end the meeting;
      a genuinely ended call finalizes and hides the companion.
- [ ] **Restart** — kill/restart Notely mid-meeting → no duplicate session, stale companion, or
      duplicate notification (full session *recovery* is not implemented — document, don't force it).

## Release gate

**Core** — [ ] shared state machine stable (done) · [ ] no duplicate sessions (dedup tested) ·
[ ] no native resource leaks (verify in stress test) · [ ] clean degradation on unsupported caps (done).
**macOS** — [x] build/test/launch-verified · [ ] interactive QA · [x] existing behavior preserved.
**Windows** — [ ] detection · [ ] notification+actions · [ ] companion · [ ] focus · [ ] DPI ·
[ ] multi-monitor · [ ] background · [ ] tray (or a documented deferral) · [ ] position persistence
(or deferral).
**Linux** — [ ] X11 companion · [ ] Wayland behavior recorded · [ ] notifications · [ ] detection ·
[ ] focus · [ ] background · [ ] tray (or deferral) · [ ] position persistence (or deferral).

**Deferred until a target OS is available to build+test on** (do not implement blind from macOS):
Windows/Linux **tray** for relaunch and companion **position persistence**. These are product gaps,
tracked here, not started — implementing them without the ability to run them would risk the builds
and can't be verified.
