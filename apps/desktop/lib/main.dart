// Entry point for the Notely desktop app.
//
// This app is responsible ONLY for UI, navigation and talking to the Rust engine over
// IPC (see `lib/ipc`). It must NOT contain media/ASR/AI/model/storage/orchestration logic —
// all of that lives in the Rust engine (`../../engine`).

import 'package:flutter/widgets.dart';

import 'app/app.dart';

void main() {
  // Required before using plugins (shared_preferences, record, file_selector).
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NotelyApp());
}
