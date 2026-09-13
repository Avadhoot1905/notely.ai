// Tests for the meeting domain: provider parsing, dedup keys, event mapping, and settings
// persistence.

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/services/meetings/meeting_event.dart';
import 'package:notely_desktop/services/meetings/meeting_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('MeetingProvider', () {
    test('round-trips through id', () {
      for (final p in MeetingProvider.values) {
        expect(MeetingProvider.fromId(p.id), p);
      }
    });
    test('unknown / alias ids map sensibly', () {
      expect(MeetingProvider.fromId('meet'), MeetingProvider.googleMeet);
      expect(MeetingProvider.fromId('google_meet'), MeetingProvider.googleMeet);
      expect(MeetingProvider.fromId('something'), MeetingProvider.generic);
      expect(MeetingProvider.fromId(null), MeetingProvider.generic);
    });
  });

  group('meetingKey dedup', () {
    test('uses provider + meetingId when present', () {
      final e = MeetingDetectedEvent(
        provider: MeetingProvider.zoom,
        startedAt: DateTime(2026),
        meetingId: '123',
      );
      expect(e.meetingKey, 'zoom:123');
    });

    test('same call re-observed shortly after yields the same key', () {
      final base = DateTime(2026, 1, 1, 10, 0);
      final a = MeetingDetectedEvent(
        provider: MeetingProvider.generic,
        startedAt: base,
        sourceApplication: 'com.google.Chrome',
      );
      final b = MeetingDetectedEvent(
        provider: MeetingProvider.generic,
        startedAt: base.add(const Duration(minutes: 3)),
        sourceApplication: 'com.google.Chrome',
      );
      expect(a.meetingKey, b.meetingKey); // same 10-min bucket → deduplicated
    });

    test('different apps produce different keys', () {
      final base = DateTime(2026, 1, 1, 10, 0);
      final a = MeetingDetectedEvent(
        provider: MeetingProvider.generic,
        startedAt: base,
        sourceApplication: 'com.google.Chrome',
      );
      final b = MeetingDetectedEvent(
        provider: MeetingProvider.generic,
        startedAt: base,
        sourceApplication: 'us.zoom.xos',
      );
      expect(a.meetingKey, isNot(b.meetingKey));
    });
  });

  test('MeetingDetectedEvent.fromMap parses native payload', () {
    final e = MeetingDetectedEvent.fromMap({
      'provider': 'teams',
      'startedAtMs': 1893456000000,
      'sourceApplication': 'com.microsoft.teams',
      'title': 'Weekly',
    });
    expect(e.provider, MeetingProvider.teams);
    expect(e.sourceApplication, 'com.microsoft.teams');
    expect(e.title, 'Weekly');
  });

  group('MeetingSettingsStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults never auto-track and include generic', () async {
      final s = await MeetingSettingsStore().load();
      expect(s.autoStartTracking, isFalse);
      expect(s.notifyOnDetect, isTrue);
      expect(s.showCompanion, isTrue);
      expect(s.enabledProviders, contains(MeetingProvider.generic));
    });

    test('round-trips through save/load', () async {
      final store = MeetingSettingsStore();
      await store.save(
        const MeetingDetectionSettings(
          enabledProviders: {MeetingProvider.zoom, MeetingProvider.teams},
          notifyOnDetect: false,
          autoStartTracking: true,
          showCompanion: false,
        ),
      );
      final s = await store.load();
      expect(s.enabledProviders, {MeetingProvider.zoom, MeetingProvider.teams});
      expect(s.notifyOnDetect, isFalse);
      expect(s.autoStartTracking, isTrue);
      expect(s.showCompanion, isFalse);
    });
  });
}
