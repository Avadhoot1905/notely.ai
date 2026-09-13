// Linux native meeting/companion runtime. See notely_runtime.h for the contract.
//
// Implements the same channels as macOS/Windows. Detection = PulseAudio/PipeWire capture streams
// (via `pactl list source-outputs`) — mic actually in use, attributed to the recording app;
// process existence alone is never a meeting. Notifications = GNotification with actions. Companion
// = a separate GTK window (always-on-top, transparent, no focus) hosting a 2nd Flutter engine.
//
// Authored on macOS; compile-gated by the Linux CI job. Wayland limits always-on-top/positioning.

#include "notely_runtime.h"

#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#include <string.h>

// Single runtime instance (GApplication actions/timeouts need access).
typedef struct {
  GtkApplication* application;
  GtkWindow* main_window;

  FlMethodChannel* capabilities_channel;
  FlMethodChannel* window_channel;
  FlMethodChannel* notifications_channel;
  FlMethodChannel* detector_channel;
  FlMethodChannel* companion_channel;

  FlEventChannel* notif_events;
  FlEventChannel* detector_events;
  FlEventChannel* companion_events;
  gboolean notif_listening;
  gboolean detector_listening;
  gboolean companion_listening;

  // Detector.
  guint poll_source_id;
  gboolean detector_running;
  gboolean meeting_active;

  // Companion.
  GtkWindow* companion_window;
  FlView* companion_view;
  FlMethodChannel* companion_incoming;  // native -> companion
  FlMethodChannel* companion_outgoing;  // companion -> native
  FlValue* last_snapshot;
  gboolean companion_expanded;
} NotelyRuntime;

static NotelyRuntime* g_rt = nullptr;

static const int kPillW = 240, kPillH = 54, kPopW = 332, kPopH = 430;

// ── helpers ──────────────────────────────────────────────────────────────────
static gboolean is_wayland() {
#ifdef GDK_WINDOWING_WAYLAND
  GdkDisplay* d = gdk_display_get_default();
  return d && GDK_IS_WAYLAND_DISPLAY(d);
#else
  return FALSE;
#endif
}

static gchar* provider_for_app_name(const gchar* app_name_lc) {
  if (!app_name_lc) return g_strdup("generic");
  if (strstr(app_name_lc, "zoom")) return g_strdup("zoom");
  if (strstr(app_name_lc, "teams")) return g_strdup("teams");
  if (strstr(app_name_lc, "discord")) return g_strdup("discord");
  if (strstr(app_name_lc, "whatsapp")) return g_strdup("whatsapp");
  if (strstr(app_name_lc, "chrome") || strstr(app_name_lc, "chromium") ||
      strstr(app_name_lc, "firefox") || strstr(app_name_lc, "edge")) {
    return g_strdup("generic");  // browser call — provider unconfirmed (same as macOS)
  }
  return g_strdup("generic");
}

static gint64 now_ms() { return g_get_real_time() / 1000; }

// ── capabilities ─────────────────────────────────────────────────────────────
static void capabilities_handler(FlMethodChannel* channel,
                                 FlMethodCall* method_call, gpointer user_data) {
  if (strcmp(fl_method_call_get_name(method_call), "get") != 0) {
    fl_method_call_respond_not_implemented(method_call, nullptr);
    return;
  }
  gboolean wayland = is_wayland();
  g_autoptr(FlValue) caps = fl_value_new_map();
  fl_value_set_string_take(caps, "meetingDetection", fl_value_new_bool(TRUE));
  fl_value_set_string_take(caps, "microphoneActivitySignal", fl_value_new_bool(TRUE));
  fl_value_set_string_take(caps, "nativeNotifications", fl_value_new_bool(TRUE));
  fl_value_set_string_take(caps, "notificationActions", fl_value_new_bool(TRUE));
  fl_value_set_string_take(caps, "companionOverlay", fl_value_new_bool(TRUE));
  // Wayland restricts always-on-top and absolute positioning; X11 supports it fully.
  fl_value_set_string_take(caps, "alwaysOnTop", fl_value_new_bool(!wayland));
  fl_value_set_string_take(caps, "transparentWindow", fl_value_new_bool(TRUE));
  fl_value_set_string_take(caps, "nonActivatingOverlay", fl_value_new_bool(!wayland));
  fl_value_set_string_take(caps, "backgroundRuntime", fl_value_new_bool(TRUE));
  fl_method_call_respond_success(method_call, caps, nullptr);
}

// ── main window focus ────────────────────────────────────────────────────────
static void window_handler(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  if (strcmp(fl_method_call_get_name(method_call), "focus") == 0) {
    if (g_rt && g_rt->main_window) {
      gtk_window_present(g_rt->main_window);
    }
    fl_method_call_respond_success(method_call, nullptr, nullptr);
  } else {
    fl_method_call_respond_not_implemented(method_call, nullptr);
  }
}

// ── notifications (GNotification + actions) ───────────────────────────────────
static void emit_notif_action(const gchar* action, const gchar* key) {
  if (!g_rt || !g_rt->notif_events) return;
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "meetingKey", fl_value_new_string(key));
  fl_value_set_string_take(map, "action", fl_value_new_string(action));
  fl_event_channel_send(g_rt->notif_events, map, nullptr, nullptr);
}

// GAction handler: parameter is "action|meetingKey".
static void on_notif_action(GSimpleAction* action, GVariant* parameter,
                            gpointer user_data) {
  if (!parameter) return;
  const gchar* s = g_variant_get_string(parameter, nullptr);
  g_auto(GStrv) parts = g_strsplit(s, "|", 2);
  if (parts && parts[0] && parts[1]) emit_notif_action(parts[0], parts[1]);
}

static void notifications_handler(FlMethodChannel* channel,
                                  FlMethodCall* method_call, gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  if (strcmp(method, "requestPermission") == 0) {
    g_autoptr(FlValue) r = fl_value_new_string("granted");
    fl_method_call_respond_success(method_call, r, nullptr);
  } else if (strcmp(method, "showMeetingPrompt") == 0) {
    FlValue* key_v = fl_value_lookup_string(args, "meetingKey");
    FlValue* title_v = fl_value_lookup_string(args, "title");
    FlValue* body_v = fl_value_lookup_string(args, "body");
    const gchar* key = key_v ? fl_value_get_string(key_v) : "";
    g_autoptr(GNotification) n = g_notification_new(
        title_v ? fl_value_get_string(title_v) : "You're in a meeting");
    if (body_v) g_notification_set_body(n, fl_value_get_string(body_v));
    g_autofree gchar* start_target = g_strdup_printf("start|%s", key);
    g_autofree gchar* dismiss_target = g_strdup_printf("dismiss|%s", key);
    g_notification_add_button_with_target_value(
        n, "Start tracking", "app.notely-notif",
        g_variant_new_string(start_target));
    g_notification_add_button_with_target_value(
        n, "Dismiss", "app.notely-notif", g_variant_new_string(dismiss_target));
    g_notification_set_default_action_and_target_value(
        n, "app.notely-notif", g_variant_new_string(start_target));
    g_application_send_notification(G_APPLICATION(g_rt->application), key, n);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
  } else if (strcmp(method, "cancel") == 0) {
    FlValue* key_v = fl_value_lookup_string(args, "meetingKey");
    if (key_v)
      g_application_withdraw_notification(G_APPLICATION(g_rt->application),
                                          fl_value_get_string(key_v));
    fl_method_call_respond_success(method_call, nullptr, nullptr);
  } else {
    fl_method_call_respond_not_implemented(method_call, nullptr);
  }
}

// ── detector (pactl capture streams) ──────────────────────────────────────────
static gchar* detect_active_capture_provider() {
  // A non-empty `source-outputs` list means some app is recording from the mic.
  // Direct argv exec (no shell parsing/interpolation) — nothing here is user-controlled anyway,
  // but this avoids ever routing a command through a shell.
  gchar* out = nullptr;
  g_autoptr(GError) error = nullptr;
  const gchar* argv[] = {"pactl", "list", "source-outputs", nullptr};
  gint status = 0;
  if (!g_spawn_sync(nullptr, (gchar**)argv, nullptr,
                    (GSpawnFlags)(G_SPAWN_SEARCH_PATH | G_SPAWN_STDERR_TO_DEV_NULL),
                    nullptr, nullptr, &out, nullptr, &status, &error)) {
    if (out) g_free(out);
    return nullptr;  // pactl unavailable (no PulseAudio/pipewire-pulse) — detection degrades to off
  }
  gchar* provider = nullptr;
  if (out && strstr(out, "Source Output #")) {
    // Find an application.name to attribute the provider.
    gchar* name_line = strstr(out, "application.name = ");
    if (name_line) {
      gchar* start = strchr(name_line, '"');
      gchar* end = start ? strchr(start + 1, '"') : nullptr;
      if (start && end) {
        g_autofree gchar* app = g_strndup(start + 1, end - start - 1);
        g_autofree gchar* lc = g_ascii_strdown(app, -1);
        provider = provider_for_app_name(lc);
      }
    }
    if (!provider) provider = g_strdup("generic");
  }
  g_free(out);
  return provider;  // nullptr = no active capture
}

static void detector_emit(const gchar* type, const gchar* provider) {
  if (!g_rt || !g_rt->detector_events) return;
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "type", fl_value_new_string(type));
  if (strcmp(type, "detected") == 0) {
    fl_value_set_string_take(map, "provider", fl_value_new_string(provider));
    fl_value_set_string_take(map, "startedAtMs", fl_value_new_int(now_ms()));
    fl_value_set_string_take(map, "sourceApplication", fl_value_new_string("linux"));
  } else {
    fl_value_set_string_take(map, "meetingKey", fl_value_new_string(""));
    fl_value_set_string_take(map, "endedAtMs", fl_value_new_int(now_ms()));
  }
  fl_event_channel_send(g_rt->detector_events, map, nullptr, nullptr);
}

static gboolean detector_poll(gpointer user_data) {
  if (!g_rt || !g_rt->detector_running) return G_SOURCE_CONTINUE;
  g_autofree gchar* provider = detect_active_capture_provider();
  if (provider && !g_rt->meeting_active) {
    g_rt->meeting_active = TRUE;
    detector_emit("detected", provider);
  } else if (!provider && g_rt->meeting_active) {
    g_rt->meeting_active = FALSE;
    detector_emit("ended", nullptr);
  }
  return G_SOURCE_CONTINUE;
}

static void detector_handler(FlMethodChannel* channel, FlMethodCall* method_call,
                             gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (strcmp(method, "start") == 0) {
    g_rt->detector_running = TRUE;
    if (g_rt->poll_source_id == 0)
      g_rt->poll_source_id = g_timeout_add_seconds(2, detector_poll, nullptr);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
  } else if (strcmp(method, "setProviders") == 0) {
    fl_method_call_respond_success(method_call, nullptr, nullptr);
  } else if (strcmp(method, "stop") == 0) {
    g_rt->detector_running = FALSE;
    if (g_rt->meeting_active) {
      g_rt->meeting_active = FALSE;
      detector_emit("ended", nullptr);
    }
    fl_method_call_respond_success(method_call, nullptr, nullptr);
  } else {
    fl_method_call_respond_not_implemented(method_call, nullptr);
  }
}

// ── companion overlay (separate GTK window + 2nd Flutter engine) ───────────────
static void companion_send_command(const gchar* cmd) {
  if (g_rt && g_rt->companion_events) {
    g_autoptr(FlValue) v = fl_value_new_string(cmd);
    fl_event_channel_send(g_rt->companion_events, v, nullptr, nullptr);
  }
}

static void companion_set_expanded(gboolean expanded);

static void companion_outgoing_handler(FlMethodChannel* channel,
                                       FlMethodCall* method_call,
                                       gpointer user_data) {
  if (strcmp(fl_method_call_get_name(method_call), "command") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    if (args && fl_value_get_type(args) == FL_VALUE_TYPE_STRING) {
      const gchar* cmd = fl_value_get_string(args);
      if (strcmp(cmd, "expand") == 0) {
        companion_set_expanded(TRUE);
      } else if (strcmp(cmd, "collapse") == 0) {
        companion_set_expanded(FALSE);
      } else if (strcmp(cmd, "beginDrag") == 0) {
        if (g_rt && g_rt->companion_window) {
          GdkDisplay* dpy = gdk_display_get_default();
          GdkSeat* seat = gdk_display_get_default_seat(dpy);
          GdkDevice* ptr = gdk_seat_get_pointer(seat);
          gint x = 0, y = 0;
          gdk_device_get_position(ptr, nullptr, &x, &y);
          gtk_window_begin_move_drag(g_rt->companion_window, 1, x, y,
                                     GDK_CURRENT_TIME);
        }
      } else {
        companion_send_command(cmd);
        if (strcmp(cmd, "openInNotely") == 0 && g_rt->main_window)
          gtk_window_present(g_rt->main_window);
      }
    }
  }
  fl_method_call_respond_success(method_call, nullptr, nullptr);
}

static void companion_build() {
  if (g_rt->companion_window) return;

  GtkWindow* win = GTK_WINDOW(gtk_window_new(GTK_WINDOW_TOPLEVEL));
  gtk_window_set_decorated(win, FALSE);
  gtk_window_set_skip_taskbar_hint(win, TRUE);
  gtk_window_set_skip_pager_hint(win, TRUE);
  gtk_window_set_keep_above(win, TRUE);  // X11; best-effort on Wayland
  gtk_window_set_type_hint(win, GDK_WINDOW_TYPE_HINT_UTILITY);
  gtk_window_set_accept_focus(win, FALSE);   // don't steal focus
  gtk_window_set_resizable(win, FALSE);
  gtk_widget_set_app_paintable(GTK_WIDGET(win), TRUE);

  // RGBA visual for transparency where the compositor supports it.
  GdkScreen* screen = gtk_widget_get_screen(GTK_WIDGET(win));
  GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
  if (visual) gtk_widget_set_visual(GTK_WIDGET(win), visual);
  gtk_window_set_default_size(win, kPillW, kPillH);

  // Second Flutter engine on main() with the companion flag.
  g_autoptr(FlDartProject) project = fl_dart_project_new();
  const char* companion_args[] = {"--notely-companion", nullptr};
  fl_dart_project_set_dart_entrypoint_arguments(project, (char**)companion_args);
  FlView* view = fl_view_new(project);
  GdkRGBA transparent;
  gdk_rgba_parse(&transparent, "#00000000");
  fl_view_set_background_color(view, &transparent);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(win), GTK_WIDGET(view));

  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* m = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_rt->companion_incoming = fl_method_channel_new(
      m, "notely/companion/incoming", FL_METHOD_CODEC(codec));
  g_rt->companion_outgoing = fl_method_channel_new(
      m, "notely/companion/outgoing", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      g_rt->companion_outgoing, companion_outgoing_handler, nullptr, nullptr);

  g_rt->companion_window = win;
  g_rt->companion_view = view;

  // Default position: bottom-right of the primary monitor (X11; Wayland ignores explicit moves).
  GdkDisplay* display = gdk_display_get_default();
  GdkMonitor* mon = gdk_display_get_primary_monitor(display);
  if (mon) {
    GdkRectangle geo;
    gdk_monitor_get_workarea(mon, &geo);
    gtk_window_move(win, geo.x + geo.width - kPillW - 24,
                    geo.y + geo.height - kPillH - 48);
  }
}

static void companion_set_expanded(gboolean expanded) {
  g_rt->companion_expanded = expanded;
  if (g_rt->companion_window) {
    gtk_window_resize(g_rt->companion_window, expanded ? kPopW : kPillW,
                      expanded ? kPopH : kPillH);
  }
  if (g_rt->companion_incoming) {
    g_autoptr(FlValue) v = fl_value_new_bool(expanded);
    fl_method_channel_invoke_method(g_rt->companion_incoming, "setExpanded", v,
                                    nullptr, nullptr, nullptr);
  }
}

static void companion_handler(FlMethodChannel* channel,
                              FlMethodCall* method_call, gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (strcmp(method, "show") == 0) {
    companion_build();
    gtk_widget_show(GTK_WIDGET(g_rt->companion_window));
    if (g_rt->companion_incoming && g_rt->last_snapshot)
      fl_method_channel_invoke_method(g_rt->companion_incoming, "update",
                                      g_rt->last_snapshot, nullptr, nullptr,
                                      nullptr);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
  } else if (strcmp(method, "hide") == 0) {
    if (g_rt->companion_window)
      gtk_widget_hide(GTK_WIDGET(g_rt->companion_window));
    if (g_rt->companion_expanded) companion_set_expanded(FALSE);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
  } else if (strcmp(method, "update") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    if (g_rt->last_snapshot) fl_value_unref(g_rt->last_snapshot);
    g_rt->last_snapshot = args ? fl_value_ref(args) : nullptr;
    if (g_rt->companion_incoming && args)
      fl_method_channel_invoke_method(g_rt->companion_incoming, "update", args,
                                      nullptr, nullptr, nullptr);
    fl_method_call_respond_success(method_call, nullptr, nullptr);
  } else {
    fl_method_call_respond_not_implemented(method_call, nullptr);
  }
}

// ── event channel stream handlers (just track listening state) ────────────────
static FlMethodErrorResponse* on_listen_notif(FlEventChannel* c, FlValue* a,
                                              gpointer u) {
  if (g_rt) g_rt->notif_listening = TRUE;
  return nullptr;
}
static FlMethodErrorResponse* on_cancel_notif(FlEventChannel* c, FlValue* a,
                                              gpointer u) {
  if (g_rt) g_rt->notif_listening = FALSE;
  return nullptr;
}
static FlMethodErrorResponse* on_listen_det(FlEventChannel* c, FlValue* a,
                                            gpointer u) {
  if (g_rt) g_rt->detector_listening = TRUE;
  return nullptr;
}
static FlMethodErrorResponse* on_cancel_det(FlEventChannel* c, FlValue* a,
                                            gpointer u) {
  if (g_rt) g_rt->detector_listening = FALSE;
  return nullptr;
}
static FlMethodErrorResponse* on_listen_comp(FlEventChannel* c, FlValue* a,
                                             gpointer u) {
  if (g_rt) g_rt->companion_listening = TRUE;
  return nullptr;
}
static FlMethodErrorResponse* on_cancel_comp(FlEventChannel* c, FlValue* a,
                                             gpointer u) {
  if (g_rt) g_rt->companion_listening = FALSE;
  return nullptr;
}

// ── entry point ──────────────────────────────────────────────────────────────
void notely_runtime_start(FlBinaryMessenger* messenger,
                          GtkApplication* application, GtkWindow* main_window) {
  if (g_rt) return;
  g_rt = g_new0(NotelyRuntime, 1);
  g_rt->application = application;
  g_rt->main_window = main_window;

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();

  g_rt->capabilities_channel = fl_method_channel_new(
      messenger, "notely/capabilities", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_rt->capabilities_channel,
                                            capabilities_handler, nullptr, nullptr);

  g_rt->window_channel =
      fl_method_channel_new(messenger, "notely/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_rt->window_channel, window_handler,
                                            nullptr, nullptr);

  // Notification action (buttons + body) → one app action carrying "action|key".
  GSimpleAction* notif_action =
      g_simple_action_new("notely-notif", G_VARIANT_TYPE_STRING);
  g_signal_connect(notif_action, "activate", G_CALLBACK(on_notif_action),
                   nullptr);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(notif_action));
  g_object_unref(notif_action);

  g_rt->notifications_channel = fl_method_channel_new(
      messenger, "notely/notifications", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      g_rt->notifications_channel, notifications_handler, nullptr, nullptr);
  g_rt->notif_events = fl_event_channel_new(
      messenger, "notely/notifications/actions", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(g_rt->notif_events, on_listen_notif,
                                       on_cancel_notif, nullptr, nullptr);

  g_rt->detector_channel = fl_method_channel_new(
      messenger, "notely/meeting_detector", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_rt->detector_channel,
                                            detector_handler, nullptr, nullptr);
  g_rt->detector_events = fl_event_channel_new(
      messenger, "notely/meeting_detector/events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(g_rt->detector_events, on_listen_det,
                                       on_cancel_det, nullptr, nullptr);

  g_rt->companion_channel = fl_method_channel_new(
      messenger, "notely/companion", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_rt->companion_channel,
                                            companion_handler, nullptr, nullptr);
  g_rt->companion_events = fl_event_channel_new(
      messenger, "notely/companion/commands", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(g_rt->companion_events, on_listen_comp,
                                       on_cancel_comp, nullptr, nullptr);
}
