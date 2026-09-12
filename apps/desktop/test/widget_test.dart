// Smoke test for the Notely app shell.
//
// With no persisted stash, the app should boot to the Stash picker. (The native folder picker
// and listening/audio flows are exercised in unit tests, not here, since they need real
// platform channels.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/app/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('boots to the Stash picker when no stash is persisted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const NotelyApp());
    await tester.pumpAndSettle();

    expect(find.text('Open a Stash'), findsOneWidget);
    expect(find.text('Choose Folder'), findsOneWidget);
    expect(find.text('Open Stash'), findsOneWidget);
  });
}
