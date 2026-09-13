// Integration test entry point.
//
// Runs the full app on a real device/desktop target via `flutter test integration_test`.
// Expand as real flows (folder pick → edit → listen → summarise) land.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notely_desktop/app/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app boots to the Stash picker with no persisted stash', (
    tester,
  ) async {
    // Start from a clean slate so a previously persisted stash doesn't skip the picker.
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const NotelyApp(autoConnectEngine: false));
    await tester.pumpAndSettle();

    expect(find.text('Open a Stash'), findsOneWidget);
  });
}
