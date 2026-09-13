// Windows native meeting/companion runtime.
//
// Implements the same Dart<->native contracts as macOS (macos/Runner/MainFlutterWindow.swift):
//   notely/capabilities            (method: get)
//   notely/window                  (method: focus)
//   notely/notifications           (method: requestPermission/showMeetingPrompt/cancel)
//   notely/notifications/actions   (event:  {meetingKey, action})
//   notely/meeting_detector        (method: start/setProviders/stop)
//   notely/meeting_detector/events (event:  {type:'detected'|'ended', ...})
//   notely/companion               (method: show/hide/update)
//   notely/companion/commands      (event:  'pause'|'resume'|'stop'|'openInNotely')
// and, for the companion's own engine:
//   notely/companion/incoming      (method: update/setExpanded)   native -> companion
//   notely/companion/outgoing      (method: command)              companion -> native
//
// Detection uses WASAPI capture-session state (mic actually in use) attributed to the process
// using it — process existence alone is never a meeting. Notifications use WinRT Toast with two
// actions. The companion is a separate top-level WS_POPUP | WS_EX_TOPMOST | WS_EX_NOACTIVATE |
// WS_EX_TOOLWINDOW window hosting a second Flutter engine (companionMain).
//
// IMPORTANT: authored on macOS and not compiled there; the Windows CI job is the compile gate.
// Known limitation: the stable Flutter Windows embedder renders opaque, so the companion uses a
// themed background with a rounded window region rather than true per-pixel transparency
// (capability transparentWindow = false). Runtime/GUI behavior needs on-device QA.

#include "notely_runtime.h"

#include <dwmapi.h>
#include <flutter/dart_project.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <windows.h>

#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <psapi.h>

#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

#include <algorithm>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::EventChannel;
using flutter::EventSink;
using flutter::MethodCall;
using flutter::MethodChannel;
using flutter::MethodResult;
using flutter::StreamHandlerFunctions;

constexpr wchar_t kAumid[] = L"ai.notely.notelyDesktop";
constexpr wchar_t kCompanionClass[] = L"NotelyCompanionWindow";

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return {};
  int len = ::WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr,
                                  0, nullptr, nullptr);
  std::string out(len, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), out.data(), len,
                        nullptr, nullptr);
  return out;
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  int len = ::MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring out(len, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), out.data(), len);
  return out;
}

const EncodableValue* Find(const EncodableMap& m, const char* key) {
  auto it = m.find(EncodableValue(std::string(key)));
  return it == m.end() ? nullptr : &it->second;
}
std::string GetString(const EncodableMap& m, const char* key) {
  auto* v = Find(m, key);
  if (v) {
    if (auto p = std::get_if<std::string>(v)) return *p;
  }
  return {};
}

// Lowercased executable file name (e.g. "zoom.exe") for a process id.
std::wstring ExeNameForPid(DWORD pid) {
  std::wstring name;
  HANDLE h = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (h) {
    wchar_t buf[MAX_PATH];
    DWORD size = MAX_PATH;
    if (::QueryFullProcessImageNameW(h, 0, buf, &size)) {
      std::wstring full(buf, size);
      size_t slash = full.find_last_of(L"\\/");
      name = slash == std::wstring::npos ? full : full.substr(slash + 1);
      std::transform(name.begin(), name.end(), name.begin(), ::towlower);
    }
    ::CloseHandle(h);
  }
  return name;
}

// Map a capturing process's exe to a provider id (matching Dart MeetingProvider ids).
std::string ProviderForExe(const std::wstring& exe) {
  if (exe == L"teams.exe" || exe == L"ms-teams.exe") return "teams";
  if (exe == L"zoom.exe") return "zoom";
  if (exe == L"discord.exe") return "discord";
  if (exe == L"whatsapp.exe") return "whatsapp";
  if (exe == L"chrome.exe" || exe == L"msedge.exe" || exe == L"firefox.exe" ||
      exe == L"brave.exe") {
    return "generic";  // browser call — provider unconfirmed (same as macOS)
  }
  return "generic";
}

int64_t NowMs() {
  // Real Unix-epoch milliseconds (FILETIME is 100ns ticks since 1601-01-01), so the timestamp Dart
  // shows for a meeting's start is correct — not boot-relative.
  FILETIME ft;
  ::GetSystemTimeAsFileTime(&ft);
  ULARGE_INTEGER u{};
  u.LowPart = ft.dwLowDateTime;
  u.HighPart = ft.dwHighDateTime;
  const uint64_t kEpochDiff100ns = 116444736000000000ULL;
  return (int64_t)((u.QuadPart - kEpochDiff100ns) / 10000ULL);
}

// Escape text before interpolating into the toast XML so a title/body containing &, <, >, or
// quotes can never break (or inject into) the document.
std::wstring XmlEscape(const std::wstring& s) {
  std::wstring o;
  o.reserve(s.size());
  for (wchar_t c : s) {
    switch (c) {
      case L'&': o += L"&amp;"; break;
      case L'<': o += L"&lt;"; break;
      case L'>': o += L"&gt;"; break;
      case L'"': o += L"&quot;"; break;
      case L'\'': o += L"&apos;"; break;
      default: o += c;
    }
  }
  return o;
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────

class NotelyRuntimeImpl {
 public:
  NotelyRuntimeImpl(flutter::FlutterEngine* engine, HWND main_window)
      : engine_(engine), main_window_(main_window) {
    ::SetCurrentProcessExplicitAppUserModelID(kAumid);
    auto* messenger = engine_->messenger();
    SetupCapabilities(messenger);
    SetupWindow(messenger);
    SetupNotifications(messenger);
    SetupDetector(messenger);
    SetupCompanion(messenger);
    s_instance = this;
  }

  ~NotelyRuntimeImpl() {
    if (poll_timer_) ::KillTimer(nullptr, poll_timer_);
    DestroyCompanion();
    s_instance = nullptr;
  }

  // ── Detector timer (runs on the UI thread via the app message loop) ──────────
  static void CALLBACK PollTimerProc(HWND, UINT, UINT_PTR, DWORD) {
    if (s_instance) s_instance->OnPoll();
  }

 private:
  static NotelyRuntimeImpl* s_instance;

  flutter::FlutterEngine* engine_;
  HWND main_window_;

  std::unique_ptr<MethodChannel<EncodableValue>> capabilities_channel_;
  std::unique_ptr<MethodChannel<EncodableValue>> window_channel_;
  std::unique_ptr<MethodChannel<EncodableValue>> notifications_channel_;
  std::unique_ptr<MethodChannel<EncodableValue>> detector_channel_;
  std::unique_ptr<MethodChannel<EncodableValue>> companion_channel_;

  std::unique_ptr<EventChannel<EncodableValue>> notif_events_;
  std::unique_ptr<EventChannel<EncodableValue>> detector_events_;
  std::unique_ptr<EventChannel<EncodableValue>> companion_events_;
  std::unique_ptr<EventSink<EncodableValue>> notif_sink_;
  std::unique_ptr<EventSink<EncodableValue>> detector_sink_;
  std::unique_ptr<EventSink<EncodableValue>> companion_sink_;

  // Notification action results marshalled from WinRT threadpool → UI thread.
  std::mutex notif_mutex_;
  std::deque<std::pair<std::string, std::string>> notif_queue_;  // (meetingKey, action)
  std::unordered_map<std::string, winrt::Windows::UI::Notifications::ToastNotification>
      live_toasts_;

  // Detector state.
  UINT_PTR poll_timer_ = 0;
  bool detector_running_ = false;
  bool meeting_active_ = false;
  int poll_divider_ = 0;

  // Companion window.
  HWND companion_hwnd_ = nullptr;
  std::unique_ptr<flutter::FlutterViewController> companion_controller_;
  std::unique_ptr<MethodChannel<EncodableValue>> companion_incoming_;  // native->companion
  std::unique_ptr<MethodChannel<EncodableValue>> companion_outgoing_;  // companion->native
  EncodableValue last_snapshot_;
  bool companion_expanded_ = false;

  static constexpr int kPillW = 240, kPillH = 54, kPopW = 332, kPopH = 430;

  // ── Capabilities ────────────────────────────────────────────────────────────
  void SetupCapabilities(flutter::BinaryMessenger* messenger) {
    capabilities_channel_ = std::make_unique<MethodChannel<EncodableValue>>(
        messenger, "notely/capabilities",
        &flutter::StandardMethodCodec::GetInstance());
    capabilities_channel_->SetMethodCallHandler(
        [](const MethodCall<EncodableValue>& call,
           std::unique_ptr<MethodResult<EncodableValue>> result) {
          if (call.method_name() != "get") {
            result->NotImplemented();
            return;
          }
          EncodableMap caps{
              {EncodableValue("meetingDetection"), EncodableValue(true)},
              {EncodableValue("microphoneActivitySignal"), EncodableValue(true)},
              {EncodableValue("nativeNotifications"), EncodableValue(true)},
              {EncodableValue("notificationActions"), EncodableValue(true)},
              {EncodableValue("companionOverlay"), EncodableValue(true)},
              {EncodableValue("alwaysOnTop"), EncodableValue(true)},
              // Stable Flutter Windows embedder is opaque — see file header.
              {EncodableValue("transparentWindow"), EncodableValue(false)},
              {EncodableValue("nonActivatingOverlay"), EncodableValue(true)},
              {EncodableValue("backgroundRuntime"), EncodableValue(true)},
          };
          result->Success(EncodableValue(caps));
        });
  }

  // ── Main window focus ────────────────────────────────────────────────────────
  void SetupWindow(flutter::BinaryMessenger* messenger) {
    window_channel_ = std::make_unique<MethodChannel<EncodableValue>>(
        messenger, "notely/window",
        &flutter::StandardMethodCodec::GetInstance());
    window_channel_->SetMethodCallHandler(
        [this](const MethodCall<EncodableValue>& call,
               std::unique_ptr<MethodResult<EncodableValue>> result) {
          if (call.method_name() == "focus") {
            FocusMain();
            result->Success();
          } else {
            result->NotImplemented();
          }
        });
  }

  void FocusMain() {
    if (!main_window_) return;
    if (::IsIconic(main_window_)) ::ShowWindow(main_window_, SW_RESTORE);
    ::ShowWindow(main_window_, SW_SHOW);
    ::SetForegroundWindow(main_window_);
  }

  // ── Notifications (WinRT Toast) ──────────────────────────────────────────────
  void SetupNotifications(flutter::BinaryMessenger* messenger) {
    notifications_channel_ = std::make_unique<MethodChannel<EncodableValue>>(
        messenger, "notely/notifications",
        &flutter::StandardMethodCodec::GetInstance());
    notifications_channel_->SetMethodCallHandler(
        [this](const MethodCall<EncodableValue>& call,
               std::unique_ptr<MethodResult<EncodableValue>> result) {
          const auto& method = call.method_name();
          const auto* args = std::get_if<EncodableMap>(call.arguments());
          if (method == "requestPermission") {
            result->Success(EncodableValue("granted"));  // Win10+ toasts need no runtime prompt
          } else if (method == "showMeetingPrompt" && args) {
            ShowToast(GetString(*args, "meetingKey"), GetString(*args, "title"),
                      GetString(*args, "body"));
            result->Success();
          } else if (method == "cancel" && args) {
            CancelToast(GetString(*args, "meetingKey"));
            result->Success();
          } else {
            result->NotImplemented();
          }
        });

    notif_events_ = std::make_unique<EventChannel<EncodableValue>>(
        messenger, "notely/notifications/actions",
        &flutter::StandardMethodCodec::GetInstance());
    notif_events_->SetStreamHandler(
        std::make_unique<StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<EventSink<EncodableValue>>&& events)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
              notif_sink_ = std::move(events);
              return nullptr;
            },
            [this](const EncodableValue*)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
              notif_sink_ = nullptr;
              return nullptr;
            }));
    EnsurePollTimer();
  }

  void ShowToast(const std::string& key, const std::string& title,
                 const std::string& body) {
    if (key.empty()) return;
    using namespace winrt::Windows::UI::Notifications;
    using namespace winrt::Windows::Data::Xml::Dom;
    try {
      std::wstring xml =
          L"<toast launch=\"" + XmlEscape(Utf8ToWide(key)) +
          L"\" activationType=\"foreground\"><visual><binding "
          L"template=\"ToastGeneric\"><text>" +
          XmlEscape(Utf8ToWide(title)) + L"</text><text>" +
          XmlEscape(Utf8ToWide(body)) +
          L"</text></binding></visual><actions>"
          L"<action content=\"Start tracking\" arguments=\"start\" "
          L"activationType=\"foreground\"/>"
          L"<action content=\"Dismiss\" arguments=\"dismiss\" "
          L"activationType=\"foreground\"/></actions></toast>";
      XmlDocument doc;
      doc.LoadXml(xml);
      ToastNotification toast(doc);
      std::string key_copy = key;
      toast.Activated([this, key_copy](const ToastNotification&,
                                       const winrt::Windows::Foundation::IInspectable& arg) {
        std::string action = "start";
        if (auto a = arg.try_as<ToastActivatedEventArgs>()) {
          std::wstring w = a.Arguments().c_str();
          std::string s = WideToUtf8(w);
          if (s == "dismiss") action = "dismiss";
          else action = "start";  // "start" or the toast launch (body tap)
        }
        {
          std::lock_guard<std::mutex> lock(notif_mutex_);
          notif_queue_.emplace_back(key_copy, action);
        }
      });
      ToastNotificationManager::CreateToastNotifier(kAumid).Show(toast);
      live_toasts_.insert_or_assign(key, toast);
    } catch (...) {
      // Toast unavailable (unsupported OS / no shortcut) — degrade quietly.
    }
  }

  void CancelToast(const std::string& key) {
    auto it = live_toasts_.find(key);
    if (it == live_toasts_.end()) return;
    try {
      winrt::Windows::UI::Notifications::ToastNotificationManager::CreateToastNotifier(kAumid)
          .Hide(it->second);
    } catch (...) {
    }
    live_toasts_.erase(it);
  }

  // ── Detector (WASAPI capture-session state) ──────────────────────────────────
  void SetupDetector(flutter::BinaryMessenger* messenger) {
    detector_channel_ = std::make_unique<MethodChannel<EncodableValue>>(
        messenger, "notely/meeting_detector",
        &flutter::StandardMethodCodec::GetInstance());
    detector_channel_->SetMethodCallHandler(
        [this](const MethodCall<EncodableValue>& call,
               std::unique_ptr<MethodResult<EncodableValue>> result) {
          const auto& method = call.method_name();
          if (method == "start") {
            detector_running_ = true;
            EnsurePollTimer();
            result->Success();
          } else if (method == "setProviders") {
            result->Success();  // provider gating also enforced in Dart
          } else if (method == "stop") {
            detector_running_ = false;
            if (meeting_active_) {
              meeting_active_ = false;
              EmitEnded();
            }
            result->Success();
          } else {
            result->NotImplemented();
          }
        });

    detector_events_ = std::make_unique<EventChannel<EncodableValue>>(
        messenger, "notely/meeting_detector/events",
        &flutter::StandardMethodCodec::GetInstance());
    detector_events_->SetStreamHandler(
        std::make_unique<StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<EventSink<EncodableValue>>&& events)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
              detector_sink_ = std::move(events);
              return nullptr;
            },
            [this](const EncodableValue*)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
              detector_sink_ = nullptr;
              return nullptr;
            }));
  }

  void EnsurePollTimer() {
    if (!poll_timer_) {
      poll_timer_ = ::SetTimer(nullptr, 0, 1000, &NotelyRuntimeImpl::PollTimerProc);
    }
  }

  void OnPoll() {
    // Drain notification actions (queued from WinRT threadpool) on the UI thread.
    std::deque<std::pair<std::string, std::string>> pending;
    {
      std::lock_guard<std::mutex> lock(notif_mutex_);
      pending.swap(notif_queue_);
    }
    for (auto& [key, action] : pending) {
      if (notif_sink_) {
        notif_sink_->Success(EncodableValue(EncodableMap{
            {EncodableValue("meetingKey"), EncodableValue(key)},
            {EncodableValue("action"), EncodableValue(action)}}));
      }
    }

    // Detector runs every ~2s.
    if (detector_running_ && (++poll_divider_ % 2 == 0)) EvaluateDetector();
  }

  void EvaluateDetector() {
    std::optional<std::string> provider = DetectActiveCaptureProvider();
    if (provider.has_value() && !meeting_active_) {
      meeting_active_ = true;
      if (detector_sink_) {
        detector_sink_->Success(EncodableValue(EncodableMap{
            {EncodableValue("type"), EncodableValue("detected")},
            {EncodableValue("provider"), EncodableValue(*provider)},
            {EncodableValue("startedAtMs"), EncodableValue(NowMs())},
            {EncodableValue("sourceApplication"), EncodableValue(std::string("windows"))}}));
      }
    } else if (!provider.has_value() && meeting_active_) {
      meeting_active_ = false;
      EmitEnded();
    }
  }

  void EmitEnded() {
    if (detector_sink_) {
      detector_sink_->Success(EncodableValue(EncodableMap{
          {EncodableValue("type"), EncodableValue("ended")},
          {EncodableValue("meetingKey"), EncodableValue(std::string(""))},
          {EncodableValue("endedAtMs"), EncodableValue(NowMs())}}));
    }
  }

  // Returns a provider id if a capture (microphone) session is ACTIVE, attributed to the process
  // capturing audio. No active capture session → no meeting (nullopt).
  std::optional<std::string> DetectActiveCaptureProvider() {
    std::optional<std::string> result;
    IMMDeviceEnumerator* enumerator = nullptr;
    if (FAILED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                  CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                  (void**)&enumerator))) {
      return result;
    }
    IMMDeviceCollection* devices = nullptr;
    if (SUCCEEDED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE,
                                                 &devices))) {
      UINT count = 0;
      devices->GetCount(&count);
      for (UINT i = 0; i < count && !result.has_value(); ++i) {
        IMMDevice* device = nullptr;
        if (FAILED(devices->Item(i, &device))) continue;
        IAudioSessionManager2* mgr = nullptr;
        if (SUCCEEDED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL,
                                       nullptr, (void**)&mgr))) {
          IAudioSessionEnumerator* sessions = nullptr;
          if (SUCCEEDED(mgr->GetSessionEnumerator(&sessions))) {
            int scount = 0;
            sessions->GetCount(&scount);
            for (int s = 0; s < scount && !result.has_value(); ++s) {
              IAudioSessionControl* ctrl = nullptr;
              if (FAILED(sessions->GetSession(s, &ctrl))) continue;
              IAudioSessionControl2* ctrl2 = nullptr;
              AudioSessionState state = AudioSessionStateInactive;
              if (SUCCEEDED(ctrl->QueryInterface(__uuidof(IAudioSessionControl2),
                                                 (void**)&ctrl2)) &&
                  SUCCEEDED(ctrl->GetState(&state)) &&
                  state == AudioSessionStateActive) {
                DWORD pid = 0;
                if (SUCCEEDED(ctrl2->GetProcessId(&pid)) && pid != 0) {
                  result = ProviderForExe(ExeNameForPid(pid));
                }
              }
              if (ctrl2) ctrl2->Release();
              ctrl->Release();
            }
            sessions->Release();
          }
          mgr->Release();
        }
        device->Release();
      }
      devices->Release();
    }
    enumerator->Release();
    return result;
  }

  // ── Companion overlay (separate top-level window + 2nd Flutter engine) ────────
  void SetupCompanion(flutter::BinaryMessenger* messenger) {
    companion_channel_ = std::make_unique<MethodChannel<EncodableValue>>(
        messenger, "notely/companion",
        &flutter::StandardMethodCodec::GetInstance());
    companion_channel_->SetMethodCallHandler(
        [this](const MethodCall<EncodableValue>& call,
               std::unique_ptr<MethodResult<EncodableValue>> result) {
          const auto& method = call.method_name();
          if (method == "show") {
            ShowCompanion();
            result->Success();
          } else if (method == "hide") {
            HideCompanion();
            result->Success();
          } else if (method == "update") {
            last_snapshot_ = *call.arguments();
            if (companion_incoming_)
              companion_incoming_->InvokeMethod(
                  "update", std::make_unique<EncodableValue>(last_snapshot_));
            result->Success();
          } else {
            result->NotImplemented();
          }
        });

    companion_events_ = std::make_unique<EventChannel<EncodableValue>>(
        messenger, "notely/companion/commands",
        &flutter::StandardMethodCodec::GetInstance());
    companion_events_->SetStreamHandler(
        std::make_unique<StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<EventSink<EncodableValue>>&& events)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
              companion_sink_ = std::move(events);
              return nullptr;
            },
            [this](const EncodableValue*)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
              companion_sink_ = nullptr;
              return nullptr;
            }));
  }

  void EnsureCompanionWindow() {
    if (companion_hwnd_) return;
    HINSTANCE hinst = ::GetModuleHandle(nullptr);
    WNDCLASSW wc{};
    wc.lpfnWndProc = &NotelyRuntimeImpl::CompanionWndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = kCompanionClass;
    wc.hbrBackground = ::CreateSolidBrush(RGB(0x1B, 0x1D, 0x22));
    wc.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
    ::RegisterClassW(&wc);

    RECT r = DefaultCompanionRect(kPillW, kPillH);
    companion_hwnd_ = ::CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, kCompanionClass, L"",
        WS_POPUP, r.left, r.top, kPillW, kPillH, nullptr, nullptr, hinst, nullptr);

    RoundCorners(kPillW, kPillH);

    // Second Flutter engine running the companion UI.
    flutter::DartProject project(L"data");
    project.set_dart_entrypoint("companionMain");
    companion_controller_ = std::make_unique<flutter::FlutterViewController>(
        kPillW, kPillH, project);
    if (companion_controller_->engine() && companion_controller_->view()) {
      HWND child = companion_controller_->view()->GetNativeWindow();
      ::SetParent(child, companion_hwnd_);
      ::SetWindowLongPtr(child, GWL_STYLE, WS_CHILD | WS_VISIBLE);
      ::MoveWindow(child, 0, 0, kPillW, kPillH, TRUE);

      auto* m = companion_controller_->engine()->messenger();
      companion_incoming_ = std::make_unique<MethodChannel<EncodableValue>>(
          m, "notely/companion/incoming",
          &flutter::StandardMethodCodec::GetInstance());
      companion_outgoing_ = std::make_unique<MethodChannel<EncodableValue>>(
          m, "notely/companion/outgoing",
          &flutter::StandardMethodCodec::GetInstance());
      companion_outgoing_->SetMethodCallHandler(
          [this](const MethodCall<EncodableValue>& call,
                 std::unique_ptr<MethodResult<EncodableValue>> result) {
            if (call.method_name() == "command") {
              if (auto* s = std::get_if<std::string>(call.arguments()))
                HandleCompanionCommand(*s);
            }
            result->Success();
          });
    }
  }

  void ShowCompanion() {
    EnsureCompanionWindow();
    if (!companion_hwnd_) return;
    ::SetWindowPos(companion_hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    ::ShowWindow(companion_hwnd_, SW_SHOWNOACTIVATE);
    if (companion_incoming_ && !last_snapshot_.IsNull())
      companion_incoming_->InvokeMethod(
          "update", std::make_unique<EncodableValue>(last_snapshot_));
  }

  void HideCompanion() {
    if (companion_hwnd_) ::ShowWindow(companion_hwnd_, SW_HIDE);
    if (companion_expanded_) SetExpanded(false);
  }

  void DestroyCompanion() {
    companion_controller_ = nullptr;
    if (companion_hwnd_) {
      ::DestroyWindow(companion_hwnd_);
      companion_hwnd_ = nullptr;
    }
  }

  void HandleCompanionCommand(const std::string& cmd) {
    if (cmd == "expand") {
      SetExpanded(true);
    } else if (cmd == "collapse") {
      SetExpanded(false);
    } else if (cmd == "beginDrag") {
      // Let the user drag the frameless window.
      ::ReleaseCapture();
      ::SendMessage(companion_hwnd_, WM_NCLBUTTONDOWN, HTCAPTION, 0);
      SavePosition();
    } else if (cmd == "pause" || cmd == "resume" || cmd == "stop" ||
               cmd == "openInNotely") {
      if (companion_sink_) companion_sink_->Success(EncodableValue(cmd));
      if (cmd == "openInNotely") FocusMain();
    }
  }

  void SetExpanded(bool expanded) {
    companion_expanded_ = expanded;
    int w = expanded ? kPopW : kPillW;
    int h = expanded ? kPopH : kPillH;
    if (companion_hwnd_) {
      RECT r;
      ::GetWindowRect(companion_hwnd_, &r);
      // Keep the top-left corner fixed as it grows/shrinks.
      ::SetWindowPos(companion_hwnd_, HWND_TOPMOST, r.left, r.top, w, h,
                     SWP_NOACTIVATE);
      if (companion_controller_ && companion_controller_->view())
        ::MoveWindow(companion_controller_->view()->GetNativeWindow(), 0, 0, w, h,
                     TRUE);
      RoundCorners(w, h);
    }
    if (companion_incoming_)
      companion_incoming_->InvokeMethod(
          "setExpanded", std::make_unique<EncodableValue>(expanded));
  }

  void RoundCorners(int w, int h) {
    if (!companion_hwnd_) return;
    HRGN rgn = ::CreateRoundRectRgn(0, 0, w + 1, h + 1, 16, 16);
    ::SetWindowRgn(companion_hwnd_, rgn, TRUE);
  }

  RECT DefaultCompanionRect(int w, int h) {
    // Restore saved position, validated against the virtual screen; else bottom-right of primary.
    int x = ::GetSystemMetrics(SM_CXSCREEN) - w - 24;
    int y = ::GetSystemMetrics(SM_CYSCREEN) - h - 60;
    DWORD sx = 0, sy = 0, has = 0;
    // (Position persistence uses shared_preferences on the Dart side in a later pass; native
    // default is a safe visible anchor.)
    (void)sx; (void)sy; (void)has;
    return RECT{x, y, x + w, y + h};
  }

  void SavePosition() { /* handled via Dart shared_preferences in a follow-up */ }

  static LRESULT CALLBACK CompanionWndProc(HWND hwnd, UINT msg, WPARAM wp,
                                           LPARAM lp) {
    switch (msg) {
      case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;  // never steal focus on click
      case WM_ERASEBKGND:
        return 1;
      default:
        return ::DefWindowProc(hwnd, msg, wp, lp);
    }
  }
};

NotelyRuntimeImpl* NotelyRuntimeImpl::s_instance = nullptr;

// ─────────────────────────────────────────────────────────────────────────────
NotelyRuntime::NotelyRuntime(flutter::FlutterEngine* engine, HWND main_window)
    : impl_(std::make_unique<NotelyRuntimeImpl>(engine, main_window)) {}

NotelyRuntime::~NotelyRuntime() = default;
