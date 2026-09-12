// Widget tests for the Notely app shell.
//
// These exercise the mock UI flow (stash picker → workspace → listening) without any engine.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/app/app.dart';

void main() {
  // Notely targets desktop window sizes; use one so the three-region layout has room.
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const NotelyApp());
  }

  testWidgets('launches to the Stash picker', (tester) async {
    await pumpApp(tester);

    expect(find.text('Open a Stash'), findsOneWidget);
    expect(find.text('Choose Folder'), findsOneWidget);
  });

  testWidgets('opening a stash reveals the workspace with the explorer', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Open Stash'));
    await tester.pumpAndSettle();

    // Picker gone, workspace visible with seeded folders + the primary action.
    expect(find.text('Open a Stash'), findsNothing);
    expect(find.text('Start listening'), findsOneWidget);
    expect(find.text('Meetings'), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget);
  });

  testWidgets('Start listening toggles the transcript panel', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Open Stash'));
    await tester.pumpAndSettle();

    expect(find.text('Live transcript'), findsNothing);

    await tester.tap(find.text('Start listening'));
    await tester.pump(); // start session
    await tester.pump(const Duration(milliseconds: 300)); // first entry + anim

    expect(find.text('Live transcript'), findsOneWidget);
    expect(find.text('Stop listening'), findsOneWidget);

    await tester.tap(find.text('Stop listening'));
    await tester.pumpAndSettle();
    expect(find.text('Live transcript'), findsNothing);
  });
}
