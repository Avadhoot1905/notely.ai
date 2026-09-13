#ifndef RUNNER_NOTELY_RUNTIME_H_
#define RUNNER_NOTELY_RUNTIME_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

G_BEGIN_DECLS

// Starts the native Linux meeting/companion runtime and wires the same Dart<->native channels as
// macOS/Windows onto the main engine's [messenger]:
//   notely/capabilities, notely/window, notely/notifications(+/actions),
//   notely/meeting_detector(+/events), notely/companion(+/commands).
//
// Detection uses PulseAudio/PipeWire capture-stream state (mic actually in use) via `pactl`;
// notifications use GNotification with actions; the companion is a separate always-on-top,
// transparent, non-focusing GTK window hosting a second Flutter engine (main() + --notely-companion).
//
// NOTE: authored on macOS and not compiled there; the Linux CI job is the compile gate. Wayland
// imposes real limits on always-on-top / positioning — reported via PlatformCapabilities.
void notely_runtime_start(FlBinaryMessenger* messenger,
                          GtkApplication* application,
                          GtkWindow* main_window);

G_END_DECLS

#endif  // RUNNER_NOTELY_RUNTIME_H_
