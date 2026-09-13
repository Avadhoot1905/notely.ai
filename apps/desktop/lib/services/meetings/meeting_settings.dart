// Meeting-detection settings model + persistence.
//
// Controls which providers are watched and how Notely reacts. Defaults are deliberately
// conservative: detect + notify, but NEVER auto-record (tracking is opt-in per the product flow —
// detection → notification → user presses "Start tracking").

import 'package:shared_preferences/shared_preferences.dart';

import 'meeting_event.dart';

class MeetingDetectionSettings {
  const MeetingDetectionSettings({
    this.enabledProviders = const {
      MeetingProvider.teams,
      MeetingProvider.zoom,
      MeetingProvider.googleMeet,
      MeetingProvider.whatsapp,
      MeetingProvider.discord,
      // Included so a mic-active browser call (e.g. Google Meet in a tab, which can't be
      // confirmed as Meet under the App Sandbox) still surfaces as a generic meeting.
      MeetingProvider.generic,
    },
    this.notifyOnDetect = true,
    this.autoStartTracking = false,
    this.showCompanion = true,
  });

  final Set<MeetingProvider> enabledProviders;
  final bool notifyOnDetect;

  /// Opt-in only. When true, a detected meeting starts tracking without waiting for the prompt.
  final bool autoStartTracking;
  final bool showCompanion;

  MeetingDetectionSettings copyWith({
    Set<MeetingProvider>? enabledProviders,
    bool? notifyOnDetect,
    bool? autoStartTracking,
    bool? showCompanion,
  }) => MeetingDetectionSettings(
    enabledProviders: enabledProviders ?? this.enabledProviders,
    notifyOnDetect: notifyOnDetect ?? this.notifyOnDetect,
    autoStartTracking: autoStartTracking ?? this.autoStartTracking,
    showCompanion: showCompanion ?? this.showCompanion,
  );
}

/// Loads/saves [MeetingDetectionSettings] via shared_preferences.
class MeetingSettingsStore {
  static const _kProviders = 'notely.meetings.enabledProviders';
  static const _kNotify = 'notely.meetings.notifyOnDetect';
  static const _kAutoTrack = 'notely.meetings.autoStartTracking';
  static const _kCompanion = 'notely.meetings.showCompanion';

  Future<MeetingDetectionSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    const defaults = MeetingDetectionSettings();
    final providerIds = prefs.getStringList(_kProviders);
    return MeetingDetectionSettings(
      enabledProviders: providerIds == null
          ? defaults.enabledProviders
          : providerIds.map(MeetingProvider.fromId).toSet(),
      notifyOnDetect: prefs.getBool(_kNotify) ?? defaults.notifyOnDetect,
      autoStartTracking:
          prefs.getBool(_kAutoTrack) ?? defaults.autoStartTracking,
      showCompanion: prefs.getBool(_kCompanion) ?? defaults.showCompanion,
    );
  }

  Future<void> save(MeetingDetectionSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _kProviders,
      s.enabledProviders.map((p) => p.id).toList(),
    );
    await prefs.setBool(_kNotify, s.notifyOnDetect);
    await prefs.setBool(_kAutoTrack, s.autoStartTracking);
    await prefs.setBool(_kCompanion, s.showCompanion);
  }
}
