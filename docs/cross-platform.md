# Cross-platform (desktop) support

Notely's desktop app (`apps/desktop`) targets **macOS, Windows and Linux** with one product and
one UI. The principle is:

> **Same product behavior, native implementation underneath.**

UI and domain code never branch on the operating system. Anything that must differ per OS
(process invocation, file reveal, audio backend, home directory) lives behind a service in
`lib/services/…` or a presentation helper in `lib/platform/`. No pure UI widget imports `dart:io`
or checks `Platform.isX`.

## Where platform-specific code is allowed

| Concern | Neutral surface | Native detail lives in |
|---|---|---|
| File ops, reveal, open-external | `FileSystemService` | `Process.run` (`open` / `explorer` / `gdbus`+`xdg-open`) |
| External-change watching | `FileWatcherService` | `Directory.watch` → FSEvents / ReadDirectoryChangesW / inotify |
| Default folder / home dir | `PathService` | `$HOME` / `%USERPROFILE%` |
| Audio capture + capabilities | `MeetingAudioService` | `record` (mic); system audio is a documented capability gap |
| File-manager name, ⌘/Ctrl hints | `PlatformUi` | `defaultTargetPlatform` (test-overridable) |
| Folder picker | `file_selector` | `file_selector_{macos,windows,linux}` |

## Filesystem semantics

- **Paths** are always built with `package:path` (`p.join`, `p.relative`, `p.equals`,
  `p.isWithin`) — never string concatenation — so separators and drive letters are handled per OS.
- **Case sensitivity.** macOS (APFS, default) and Windows (NTFS) are case-*insensitive*; most Linux
  filesystems are case-*sensitive*. A rename that only changes case (`notes.md` → `Notes.md`) is
  detected and performed via a temporary name so it doesn't self-collide on case-insensitive
  filesystems.
- **Line endings.** Editing happens in LF in-memory; the file's original ending (LF or CRLF) is
  remembered on open and restored on save, so a Windows-authored CRLF file is never silently
  rewritten to LF.
- **Markdown image links** are written with `/` separators on every OS (portable links).
- **Unicode / spaces / punctuation** in file and folder names are supported (covered by tests).

## File reveal

| OS | Mechanism |
|---|---|
| macOS | `open -R <path>` (Finder, item highlighted) |
| Windows | `explorer /select,<path>` (item highlighted) |
| Linux | `org.freedesktop.FileManager1.ShowItems` via `gdbus` (highlights the item in Nautilus/Dolphin/Nemo/…), falling back to `xdg-open` on the folder |

Linux reveal makes **no assumption about the desktop environment or file manager**.

## Audio

Microphone capture works on all three platforms via the `record` package. **System / call audio
(loopback) is not yet captured on any platform** — it requires a native loopback path
(macOS ScreenCaptureKit, Windows WASAPI loopback, Linux PulseAudio/PipeWire monitor) that will be
implemented in the Rust engine. This is reported honestly through `AudioCapabilities`
(`systemAudio: unsupported` with a per-OS note) rather than failing silently. The listening state
machine treats permission-denied / unavailable audio as coherent UI states, not crashes.

## Inference runtimes

The application pipeline is **platform-independent**: every runtime sits behind `LlmProvider`
(and `AsrProvider`) in the Rust engine, reached over a process/HTTP boundary, so no OS-specific
inference logic leaks into the pipeline or the UI.

| Platform | LLM path |
|---|---|
| macOS (Apple Silicon) | **Ollama** (Metal) by default, or **MLX** via an external `mlx_lm.server` (`NOTELY_LLM_PROVIDER=mlx`) |
| Linux / Windows — NVIDIA | **Ollama → CUDA** (Ollama detects the GPU automatically) |
| Linux / Windows — CPU | **Ollama → CPU** |

- **MLX is macOS-only and opt-in.** It is never linked into the engine; it runs as a separate local
  HTTP server, mirroring how Ollama and the ASR runtime already work. If it isn't running, the
  engine defers work rather than failing, and Linux/Windows behavior is unchanged.
- **No CUDA code lives in Notely.** GPU acceleration on NVIDIA is entirely Ollama's job; the
  provider boundary leaves room for a future GPU runtime (e.g. vLLM) as just another provider.
- **Hybrid search, persistent jobs, and the LLM cache are pure SQLite** (bundled `rusqlite`), so
  they behave identically on all three platforms. Hybrid search is off until an embedding model is
  configured (`NOTELY_LLM_MODEL_EMBEDDING`).

## Linux baseline

Primary validation target: **Ubuntu 24.04 LTS · GNOME · Wayland**. The architecture is kept
compatible with Fedora, KDE and X11 — no GNOME-specific behavior is hardcoded. Known Linux
caveats:

- **Recursive file watching** (inotify) is not guaranteed across all kernels/backends; the watcher
  falls back to a top-level watch, so deep external edits may need a manual refresh.
- **System-audio capture** is unavailable (see above).
- Reveal-with-highlight needs a running session bus + a FileManager1 implementation; otherwise it
  opens the containing folder.

## Keyboard

Shortcuts are defined with both the macOS command modifier (`meta:`) and the Windows/Linux modifier
(`control:`) so each OS reads natively (⌘ vs Ctrl); structural keys (Esc, F2, Delete) are shared.

## Build & runtime status

See the final section of the hardening report / PR description. macOS is build-verified here;
Windows and Linux are static/analysis-verified (they cannot be compiled from a macOS host — Linux
additionally needs GTK + cmake/ninja on a Linux machine).
