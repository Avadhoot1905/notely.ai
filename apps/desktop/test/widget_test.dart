// Basic widget test for the Notely app shell.

import 'package:flutter_test/flutter_test.dart';
import 'package:notely_desktop/app/app.dart';

void main() {
  testWidgets('app renders the meetings landing screen', (tester) async {
    await tester.pumpWidget(const NotelyApp());

    expect(find.text('Notely — Meetings'), findsOneWidget);
    expect(find.textContaining('No meetings yet'), findsOneWidget);
  });
}
