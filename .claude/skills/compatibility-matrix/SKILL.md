---
name: compatibility-matrix
description: Load when reasoning about which platform/runtime/feature combinations Notely supports and at what verification level. The single place that separates "verified", "compile-gated only", and "known gap" — so you never claim unverified behavior.
---

# compatibility-matrix

## Verification legend
`✓` verified on the dev host (compiles + tests pass; macOS also launches) · `⧗` implemented but
**compile-gated by CI only, not runtime-QA'd** · `~` limited · `!` genuine OS restriction · `✗` not implemented.

## Platform × LLM runtime
| Platform | LLM path |
|---|---|
| macOS (Apple Silicon) | Ollama→Metal (default) `✓`, or MLX via external `mlx_lm.server` (opt-in) `~` |
| Linux/Windows — NVIDIA | Ollama→CUDA (Ollama auto-detects) `⧗` |
| Linux/Windows — CPU | Ollama→CPU `⧗` |
MLX is **macOS-only/opt-in, never linked**; **no CUDA code in Notely** (cuda, apple-silicon).

## ASR runtime
Qwen3-ASR (default, separate HTTP runtime) — **audio path scaffolded, not end-to-end** · Whisper —
`NotImplemented` · `fixture` — tests. Transcript input needs no ASR (asr).

## Desktop meeting/companion features (from docs/meeting-companion.md)
| Capability | macOS | Windows | Linux X11 | Linux Wayland |
|---|---|---|---|---|
| Meeting detection (mic+app) | ✓ | ⧗ | ⧗ | ⧗ |
| Notifications (+actions) | ✓ | ⧗ | ⧗ | ⧗ |
| Companion overlay | ✓ | ⧗ | ⧗ | ⧗ |
| Always-on-top | ✓ | ⧗ | ⧗ | ! compositor restricts |
| Transparency | ✓ | ~ opaque | ⧗ | ⧗ |
| Non-activating (no focus steal) | ✓ | ⧗ | ⧗ | ! varies |
| Position persistence | ~ (UserDefaults) | ✗ TODO | ✗ TODO | ✗ TODO |
| Tray / relaunch | ~ (Dock) | ✗ TODO | ✗ TODO | ✗ TODO |
| System audio (loopback) | ✗ | ✗ | ✗ | ✗ (all: known gap) |

## Baselines
- **Reference host:** macOS Apple Silicon — build/test/launch-verified.
- **Linux primary target:** Ubuntu 24.04 · GNOME · Wayland (kept compatible with Fedora/KDE/X11).
- Hybrid search / persistent jobs / LLM cache are **pure SQLite** → identical on all three platforms.

## Rule
**Never present a `⧗` / `✗` / `~` cell as verified.** Windows/Linux GUI behavior and the audio→ASR
path are not runtime-verified here; say so (no-speculation). Update this matrix and
`docs/meeting-companion.md` together when reality changes.

## Related skills
desktop · overlay · release-engineering · apple-silicon · cuda · asr · no-speculation
