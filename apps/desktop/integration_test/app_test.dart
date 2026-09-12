// Integration test entry point.
//
// Runs the full app on a real device/desktop target via `flutter test integration_test`.
// Kept minimal for the scaffold; expand as real flows (import → transcript → MOM) land.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notely_desktop/app/app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app boots to the Stash picker', (tester) async {
    await tester.pumpWidget(const NotelyApp());
    await tester.pumpAndSettle();

    expect(find.text('Open Stash'), findsOneWidget);
  });
}
