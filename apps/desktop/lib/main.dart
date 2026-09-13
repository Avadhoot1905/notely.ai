// Entry point for the Notely desktop app.
//
// This app is responsible ONLY for UI, navigation and talking to the Rust engine over
// IPC (see `lib/ipc`). It must NOT contain media/ASR/AI/model/storage/orchestration logic —
// all of that lives in the Rust engine (`../../engine`).

import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'companion/companion_main.dart';

/// Flag passed by native runners that host the companion in a second Flutter engine via the
/// default `main` entrypoint. macOS and Windows can select the `companionMain` entrypoint by name,
/// but the Linux (GTK) embedder can only pass *arguments* to `main`, so the companion engine is
/// launched with this flag and dispatched here. Harmless on the platforms that don't use it.
const kCompanionFlag = '--notely-companion';

void main(List<String> args) {
  if (args.contains(kCompanionFlag)) {
    companionMain();
    return;
  }
  // Required before using plugins (shared_preferences, record, file_selector).
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NotelyApp());
}
