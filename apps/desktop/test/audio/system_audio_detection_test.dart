// Tests for the loopback-device detection used by system-audio capture.
//
// These cover the pure, hardware-free selection logic: which devices count as a system-audio
// capture endpoint and which must NOT (a plain microphone, an output-only device). The concrete
// RecordMeetingAudioService lifecycle is exercised through ListeningController in session_test.dart
// with a fake service, because it needs the platform audio plugin channel.

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/services/audio/meeting_audio_service.dart';
import 'package:record/record.dart';

InputDevice dev(String label, {String? id}) =>
    InputDevice(id: id ?? label, label: label);

void main() {
  // macOS-priority hints (tests run on macOS here). Passed explicitly so the assertions don't
  // depend on the host platform.
  const macHints = [
    'blackhole',
    'background music',
    'soundflower',
    'loopback',
    'aggregate',
  ];

  group('selectLoopbackDevice', () {
    test('recognizes BlackHole as a loopback input', () {
      final devices = [dev('MacBook Pro Microphone'), dev('BlackHole 2ch')];
      expect(selectLoopbackDevice(devices, macHints)?.label, 'BlackHole 2ch');
    });

    test('recognizes Background Music as a loopback input', () {
      final devices = [dev('Background Music'), dev('MacBook Pro Microphone')];
      expect(
        selectLoopbackDevice(devices, macHints)?.label,
        'Background Music',
      );
    });

    test('does NOT classify an ordinary microphone as system audio', () {
      final devices = [dev('MacBook Pro Microphone'), dev('External USB Mic')];
      expect(selectLoopbackDevice(devices, macHints), isNull);
    });

    test('returns null when there is no loopback device', () {
      expect(selectLoopbackDevice(const [], macHints), isNull);
    });

    test('is case-insensitive', () {
      final devices = [dev('BLACKHOLE 16ch')];
      expect(selectLoopbackDevice(devices, macHints)?.label, 'BLACKHOLE 16ch');
    });

    test('ranks a real virtual device above a generic aggregate', () {
      // Aggregate is last-resort; a BlackHole present should win even if listed after it.
      final devices = [dev('My Aggregate Device'), dev('BlackHole 2ch')];
      expect(selectLoopbackDevice(devices, macHints)?.label, 'BlackHole 2ch');
    });

    test(
      'falls back to an aggregate only when nothing more specific matches',
      () {
        final devices = [
          dev('MacBook Pro Microphone'),
          dev('Studio Aggregate'),
        ];
        expect(
          selectLoopbackDevice(devices, macHints)?.label,
          'Studio Aggregate',
        );
      },
    );

    test('selects by stable id (identity preserved), not just label', () {
      final target = dev('BlackHole 2ch', id: 'uid-blackhole-123');
      final devices = [dev('MacBook Pro Microphone', id: 'uid-mic'), target];
      expect(selectLoopbackDevice(devices, macHints)?.id, 'uid-blackhole-123');
    });
  });

  group('platform hints', () {
    test('macOS hints do not include output-only "multi-output"', () {
      // A Multi-Output device is output-only and never a capture endpoint — it must not be a hint.
      expect(loopbackHintsForPlatform(), isNot(contains('multi-output')));
    });

    test(
      'macOS hints do not include the ambiguous "monitor" (matches displays)',
      () {
        // "monitor" is a Linux PulseAudio concept; on macOS it can hit a display's audio device.
        expect(loopbackHintsForPlatform(), isNot(contains('monitor')));
      },
    );

    test('a device named like a display "…Monitor" is not picked on macOS', () {
      final devices = [dev('LG UltraFine Display Monitor')];
      expect(selectLoopbackDevice(devices, loopbackHintsForPlatform()), isNull);
    });
  });
}
