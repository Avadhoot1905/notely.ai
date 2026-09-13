#ifndef RUNNER_NOTELY_RUNTIME_H_
#define RUNNER_NOTELY_RUNTIME_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

#include <memory>

// Native Windows meeting/companion runtime. Mirrors the macOS NotelyRuntime: it wires the same
// Dart<->native channels (notely/capabilities, notely/notifications, notely/meeting_detector,
// notely/companion, notely/window) onto the MAIN Flutter engine and owns the Windows-native
// implementations behind them (WASAPI detection, Toast notifications, a layered/topmost/no-activate
// companion window hosting a second Flutter engine).
//
// NOTE: written on macOS and NOT compiled/verified there — compile-gated by the Windows CI job.
class NotelyRuntimeImpl;

class NotelyRuntime {
 public:
  NotelyRuntime(flutter::FlutterEngine* engine, HWND main_window);
  ~NotelyRuntime();

  NotelyRuntime(const NotelyRuntime&) = delete;
  NotelyRuntime& operator=(const NotelyRuntime&) = delete;

 private:
  std::unique_ptr<NotelyRuntimeImpl> impl_;
};

#endif  // RUNNER_NOTELY_RUNTIME_H_
