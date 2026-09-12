// Meetings feature — placeholder landing screen.
//
// Features are organized by product area (meetings, transcript, MOM, recording/import,
// settings). Each feature owns its own widgets/state and reaches the engine only through
// the IPC client in `lib/ipc`. This page is a scaffold; real meeting-list UI and its wiring
// to `EngineClient.getMeeting(...)` land later.

import 'package:flutter/material.dart';

class MeetingListPage extends StatelessWidget {
  const MeetingListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notely — Meetings')),
      body: const Center(
        // TODO: render the meeting list from the engine and support recording/import.
        child: Text('No meetings yet. (Scaffold)'),
      ),
    );
  }
}
