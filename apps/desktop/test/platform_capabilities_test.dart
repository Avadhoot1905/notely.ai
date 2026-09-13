// Tests for the platform capability matrix and honest degradation on unsupported platforms.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/services/platform/platform_capabilities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformCapabilities.fallback matrix', () {
    test('macOS is fully capable', () {
      final c = PlatformCapabilities.fallback(TargetPlatform.macOS);
      expect(c.meetingDetection, isTrue);
      expect(c.nativeNotifications, isTrue);
      expect(c.notificationActions, isTrue);
      expect(c.companionOverlay, isTrue);
      expect(c.alwaysOnTop, isTrue);
      expect(c.transparentWindow, isTrue);
      expect(c.nonActivatingOverlay, isTrue);
      expect(c.backgroundRuntime, isTrue);
    });

    test(
      'Windows reports unimplemented (honest) with planned-mechanism notes',
      () {
        final c = PlatformCapabilities.fallback(TargetPlatform.windows);
        expect(c.meetingDetection, isFalse);
        expect(c.nativeNotifications, isFalse);
        expect(c.companionOverlay, isFalse);
        expect(c.notes['companionOverlay'], contains('WS_EX_'));
        expect(c.notes['nativeNotifications'], contains('Toast'));
      },
    );

    test('Linux reports unimplemented with Wayland/layer-shell caveats', () {
      final c = PlatformCapabilities.fallback(TargetPlatform.linux);
      expect(c.meetingDetection, isFalse);
      expect(c.companionOverlay, isFalse);
      expect(c.notes['companionOverlay'], contains('layer-shell'));
      expect(c.notes['meetingDetection'], contains('PipeWire'));
    });
  });

  test('fromMap parses a native capability payload', () {
    final c = PlatformCapabilities.fromMap({
      'meetingDetection': true,
      'nativeNotifications': true,
      'companionOverlay': false,
    });
    expect(c.meetingDetection, isTrue);
    expect(c.nativeNotifications, isTrue);
    expect(c.companionOverlay, isFalse);
    expect(c.alwaysOnTop, isFalse); // missing keys default to false
  });

  test(
    'resolve() falls back to the per-OS matrix when no native handler',
    () async {
      // No method-channel handler is registered in the test harness, so resolve() must fall back.
      final svc = PlatformCapabilitiesService(platform: TargetPlatform.linux);
      final c = await svc.resolve();
      expect(c.meetingDetection, isFalse); // Linux fallback
    },
  );
}
