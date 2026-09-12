// Root application widget: wires up theming and top-level navigation.
//
// `app/` holds app-wide concerns (root widget, theme, routing, shared shell). Individual
// screens live under `features/`.

import 'package:flutter/material.dart';

import '../features/meetings/meeting_list_page.dart';

class NotelyApp extends StatelessWidget {
  const NotelyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notely',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3A6EA5)),
        useMaterial3: true,
      ),
      home: const MeetingListPage(),
    );
  }
}
