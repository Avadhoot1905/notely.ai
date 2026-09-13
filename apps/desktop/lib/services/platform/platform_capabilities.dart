// Platform capability model.
//
// The meeting/companion feature is implemented natively per-OS, and each OS exposes a different
// subset of the required capabilities. Rather than scattering `if (isMacOS)` through the app, the
// runtime asks HERE what the current platform can actually do, and degrades honestly (e.g. don't
// attempt a companion overlay where none exists; a settings UI can gray out unsupported options).
//
// Source of truth is the native `notely/capabilities` channel: the OS that has an implementation
// reports exactly what it supports. When there's no native handler (a platform whose adapter isn't
// written yet, or a test/headless run) we fall back to a conservative, HONEST per-OS matrix — not
// an optimistic one. This is the single place the cross-platform matrix lives in code.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.meetingDetection,
    required this.microphoneActivitySignal,
    required this.nativeNotifications,
    required this.notificationActions,
    required this.companionOverlay,
    required this.alwaysOnTop,
    required this.transparentWindow,
    required this.nonActivatingOverlay,
    required this.backgroundRuntime,
    this.notes = const {},
  });

  /// Can the OS tell us the user (likely) joined a meeting at all?
  final bool meetingDetection;

  /// Can we observe the microphone being in use system-wide (the meeting gate)?
  final bool microphoneActivitySignal;

  /// Real OS notifications (not an in-app banner).
  final bool nativeNotifications;

  /// Action buttons on those notifications (Start tracking / Dismiss).
  final bool notificationActions;

  /// A separate, OS-level companion overlay window.
  final bool companionOverlay;

  /// The overlay can float above other apps' windows.
  final bool alwaysOnTop;

  /// The overlay window can be transparent/frameless.
  final bool transparentWindow;

  /// The overlay can be shown/clicked without stealing focus from the active app.
  final bool nonActivatingOverlay;

  /// The runtime keeps running when the main window is closed.
  final bool backgroundRuntime;

  /// Per-capability human-readable caveats (keyed by capability name) for the UI/report.
  final Map<String, String> notes;

  bool get anyMeetingSupport => meetingDetection || nativeNotifications;

  /// Conservative, honest defaults when native reports nothing. Only macOS has a shipped native
  /// implementation today; Windows/Linux adapters are not yet written, so they report false
  /// (feature absent, not faked) with a note pointing at the planned mechanism.
  factory PlatformCapabilities.fallback(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.macOS:
        return const PlatformCapabilities(
          meetingDetection: true,
          microphoneActivitySignal: true,
          nativeNotifications: true,
          notificationActions: true,
          companionOverlay: true,
          alwaysOnTop: true,
          transparentWindow: true,
          nonActivatingOverlay: true,
          backgroundRuntime: true,
        );
      case TargetPlatform.windows:
        return const PlatformCapabilities(
          meetingDetection: false,
          microphoneActivitySignal: false,
          nativeNotifications: false,
          notificationActions: false,
          companionOverlay: false,
          alwaysOnTop: false,
          transparentWindow: false,
          nonActivatingOverlay: false,
          backgroundRuntime: false,
          notes: {
            'meetingDetection':
                'Planned: WASAPI capture-state + process enumeration (native adapter not yet built).',
            'nativeNotifications':
                'Planned: Windows Toast (WinRT) with actions; needs AppUserModelID registration.',
            'companionOverlay':
                'Planned: WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_NOACTIVATE window hosting a 2nd Flutter engine.',
          },
        );
      case TargetPlatform.linux:
        return const PlatformCapabilities(
          meetingDetection: false,
          microphoneActivitySignal: false,
          nativeNotifications: false,
          notificationActions: false,
          companionOverlay: false,
          alwaysOnTop: false,
          transparentWindow: false,
          nonActivatingOverlay: false,
          backgroundRuntime: false,
          notes: {
            'meetingDetection':
                'Planned: PipeWire/PulseAudio source-in-use + process scan (native adapter not yet built).',
            'nativeNotifications':
                'Planned: GNotification/libnotify with actions (D-Bus org.freedesktop.Notifications).',
            'companionOverlay':
                'Planned: GTK layer-shell (Wayland) / override-redirect + _NET_WM_STATE_ABOVE (X11); always-on-top is not guaranteed on all Wayland compositors.',
          },
        );
      default:
        return const PlatformCapabilities(
          meetingDetection: false,
          microphoneActivitySignal: false,
          nativeNotifications: false,
          notificationActions: false,
          companionOverlay: false,
          alwaysOnTop: false,
          transparentWindow: false,
          nonActivatingOverlay: false,
          backgroundRuntime: false,
        );
    }
  }

  factory PlatformCapabilities.fromMap(Map<dynamic, dynamic> map) {
    bool b(String k) => map[k] == true;
    return PlatformCapabilities(
      meetingDetection: b('meetingDetection'),
      microphoneActivitySignal: b('microphoneActivitySignal'),
      nativeNotifications: b('nativeNotifications'),
      notificationActions: b('notificationActions'),
      companionOverlay: b('companionOverlay'),
      alwaysOnTop: b('alwaysOnTop'),
      transparentWindow: b('transparentWindow'),
      nonActivatingOverlay: b('nonActivatingOverlay'),
      backgroundRuntime: b('backgroundRuntime'),
    );
  }
}

/// Resolves [PlatformCapabilities] for the running platform.
class PlatformCapabilitiesService {
  PlatformCapabilitiesService({
    MethodChannel? channel,
    TargetPlatform? platform,
  }) : _channel = channel ?? const MethodChannel('notely/capabilities'),
       _platform = platform ?? defaultTargetPlatform;

  final MethodChannel _channel;
  final TargetPlatform _platform;

  /// Ask native for the real capabilities; fall back to the honest per-OS default when there's no
  /// native handler (unimplemented platform / headless test).
  Future<PlatformCapabilities> resolve() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('get');
      if (map != null) return PlatformCapabilities.fromMap(map);
    } catch (_) {
      // No native handler / native error / channel unavailable — use the honest fallback matrix.
      // Capability probing must never throw: an unknown platform is simply "not capable".
    }
    return PlatformCapabilities.fallback(_platform);
  }
}
