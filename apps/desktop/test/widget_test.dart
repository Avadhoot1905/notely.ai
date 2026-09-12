// Smoke + theming tests for the Notely app shell.
//
// - With no persisted stash, the app boots to the Stash picker (dark = default theme).
// - With a persisted light-theme preference, the app restores and renders the picker in the
//   light theme cleanly — guarding against hard-coded colors that only work in one theme.
// (Native folder picker / audio flows are covered in unit tests — they need platform channels.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/app/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  void desktopSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('boots to the Stash picker in the default (dark) theme', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    desktopSize(tester);
    await tester.pumpWidget(const NotelyApp());
    await tester.pumpAndSettle();

    // The two-pane launch modal: identity + create/open actions.
    expect(find.text('Create new Stash'), findsOneWidget);
    expect(find.text('Open folder as Stash'), findsOneWidget);
    expect(find.text('YOUR STASHES'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restores and renders the light theme from preferences', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'notely.theme.mode': 'light'});
    desktopSize(tester);
    await tester.pumpWidget(const NotelyApp());
    await tester.pumpAndSettle();

    // Real screen renders under the light theme with no exceptions/overflow.
    expect(find.text('Create new Stash'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final MaterialApp app = tester.widget(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.light);
  });
}
