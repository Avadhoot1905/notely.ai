import Cocoa
import CoreAudio
import FlutterMacOS
import UserNotifications

// ─────────────────────────────────────────────────────────────────────────────
// Main window — hosts the primary Flutter engine and boots the native meeting runtime
// (notifications, detector, companion overlay). All of this lives in native code so it keeps
// working while the main window is closed/minimized (see AppDelegate background-runtime config).
// ─────────────────────────────────────────────────────────────────────────────
class MainFlutterWindow: NSWindow {
  private var runtime: NotelyRuntime?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    runtime = NotelyRuntime(
      messenger: flutterViewController.engine.binaryMessenger,
      mainWindow: self
    )

    super.awakeFromNib()
  }
}

/// Holds an event-channel sink and forwards on the main thread.
final class SinkHolder: NSObject, FlutterStreamHandler {
  var sink: FlutterEventSink?
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
  func send(_ value: Any) {
    if Thread.isMainThread {
      sink?(value)
    } else {
      DispatchQueue.main.async { [weak self] in self?.sink?(value) }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Runtime coordinator — wires all channels for the MAIN engine.
// ─────────────────────────────────────────────────────────────────────────────
final class NotelyRuntime {
  private let notifications: NotificationBridge
  private let detector: MeetingDetectorBridge
  private let companion: CompanionController
  private let windowChannel: FlutterMethodChannel
  private let capabilitiesChannel: FlutterMethodChannel
  private weak var mainWindow: NSWindow?

  init(messenger: FlutterBinaryMessenger, mainWindow: NSWindow) {
    self.mainWindow = mainWindow
    notifications = NotificationBridge(messenger: messenger)
    detector = MeetingDetectorBridge(messenger: messenger)
    companion = CompanionController(messenger: messenger, mainWindow: mainWindow)

    // Report the capabilities macOS actually implements (see PlatformCapabilities in Dart).
    capabilitiesChannel = FlutterMethodChannel(
      name: "notely/capabilities", binaryMessenger: messenger)
    capabilitiesChannel.setMethodCallHandler { call, result in
      if call.method == "get" {
        result([
          "meetingDetection": true,
          "microphoneActivitySignal": true,
          "nativeNotifications": true,
          "notificationActions": true,
          "companionOverlay": true,
          "alwaysOnTop": true,
          "transparentWindow": true,
          "nonActivatingOverlay": true,
          "backgroundRuntime": true,
        ])
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    windowChannel = FlutterMethodChannel(name: "notely/window", binaryMessenger: messenger)
    windowChannel.setMethodCallHandler { [weak mainWindow] call, result in
      if call.method == "focus" {
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Native OS notifications with Start/Dismiss actions (UNUserNotificationCenter).
// Works with the main window closed/minimized because it's an OS notification, not an in-app UI.
// ─────────────────────────────────────────────────────────────────────────────
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
  private let method: FlutterMethodChannel
  private let actions = SinkHolder()
  private static let categoryId = "NOTELY_MEETING"
  private static let startAction = "NOTELY_START"
  private static let dismissAction = "NOTELY_DISMISS"

  init(messenger: FlutterBinaryMessenger) {
    method = FlutterMethodChannel(name: "notely/notifications", binaryMessenger: messenger)
    super.init()

    let events = FlutterEventChannel(
      name: "notely/notifications/actions", binaryMessenger: messenger)
    events.setStreamHandler(actions)

    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let start = UNNotificationAction(
      identifier: Self.startAction, title: "Start tracking", options: [.foreground])
    let dismiss = UNNotificationAction(
      identifier: Self.dismissAction, title: "Dismiss", options: [])
    let category = UNNotificationCategory(
      identifier: Self.categoryId, actions: [start, dismiss], intentIdentifiers: [], options: [])
    center.setNotificationCategories([category])

    method.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    switch call.method {
    case "requestPermission":
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        result(granted ? "granted" : "denied")
      }
    case "showMeetingPrompt":
      guard let args = call.arguments as? [String: Any],
        let key = args["meetingKey"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "meetingKey required", details: nil))
        return
      }
      let content = UNMutableNotificationContent()
      content.title = (args["title"] as? String) ?? "You're in a meeting"
      content.body = (args["body"] as? String) ?? "Track notes for this meeting?"
      content.categoryIdentifier = Self.categoryId
      content.userInfo = ["meetingKey": key]
      let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
      center.add(request) { _ in result(nil) }
    case "cancel":
      if let args = call.arguments as? [String: Any], let key = args["meetingKey"] as? String {
        center.removePendingNotificationRequests(withIdentifiers: [key])
        center.removeDeliveredNotifications(withIdentifiers: [key])
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // Show the banner even when Notely is frontmost.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(macOS 11.0, *) {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  // The user pressed a button (or the notification body).
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let key =
      (response.notification.request.content.userInfo["meetingKey"] as? String)
      ?? response.notification.request.identifier
    let action: String
    switch response.actionIdentifier {
    case Self.startAction, UNNotificationDefaultActionIdentifier:
      action = "start"
    default:
      action = "dismiss"
    }
    actions.send(["meetingKey": key, "action": action])
    completionHandler()
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Meeting detector — a running conferencing app PLUS the microphone actually being in use.
// "App is open" alone is NOT treated as "in a meeting"; the mic-in-use signal is the gate.
// Sandbox note: reading other apps' window titles via Accessibility is unreliable under the App
// Sandbox, so we do NOT try to read a browser's tab to confirm "Google Meet" — a mic-active
// browser is reported as a generic meeting. Precise in-browser Meet detection needs a browser
// extension (documented limitation), rather than a fabricated detector.
// ─────────────────────────────────────────────────────────────────────────────
final class MeetingDetectorBridge {
  private let method: FlutterMethodChannel
  private let events = SinkHolder()
  private var enabled: Set<String> = []
  private var timer: Timer?
  private var active = false
  private var activeKey: String?

  // bundle id → provider id
  private static let dedicatedApps: [String: String] = [
    "us.zoom.xos": "zoom",
    "com.microsoft.teams": "teams",
    "com.microsoft.teams2": "teams",
    "com.hnc.Discord": "discord",
    "net.whatsapp.WhatsApp": "whatsapp",
    "WhatsApp": "whatsapp",
  ]
  private static let browsers: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.beta", "com.apple.Safari",
    "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
  ]

  init(messenger: FlutterBinaryMessenger) {
    method = FlutterMethodChannel(name: "notely/meeting_detector", binaryMessenger: messenger)
    let eventChannel = FlutterEventChannel(
      name: "notely/meeting_detector/events", binaryMessenger: messenger)
    eventChannel.setStreamHandler(events)

    method.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "start":
        self.setProviders(call.arguments)
        self.start()
        result(nil)
      case "setProviders":
        self.setProviders(call.arguments)
        result(nil)
      case "stop":
        self.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func setProviders(_ arguments: Any?) {
    if let args = arguments as? [String: Any], let list = args["providers"] as? [String] {
      enabled = Set(list)
    }
  }

  private func start() {
    guard timer == nil else { return }
    // Low-frequency evaluation (2s) — not a busy loop. Combines a couple of CoreAudio property
    // reads with a running-apps scan. Could be upgraded to CoreAudio property listeners later.
    let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.evaluate() }
    RunLoop.main.add(t, forMode: .common)
    timer = t
    evaluate()
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
    if active {
      active = false
      activeKey = nil
      events.send(["type": "ended", "meetingKey": "", "endedAtMs": Self.nowMs()])
    }
  }

  private func evaluate() {
    let micOn = Self.isMicrophoneActive()
    if micOn, !active {
      guard let (provider, bundleId) = detectProvider() else { return }
      if !enabled.isEmpty && !enabled.contains(provider) { return }
      active = true
      let started = Self.nowMs()
      activeKey = ""  // Dart derives the key; we only need to pair detected/ended.
      events.send([
        "type": "detected",
        "provider": provider,
        "startedAtMs": started,
        "sourceApplication": bundleId,
      ])
    } else if !micOn, active {
      active = false
      activeKey = nil
      events.send(["type": "ended", "meetingKey": "", "endedAtMs": Self.nowMs()])
    }
  }

  /// Pick the most specific running conferencing app; else a running browser (generic).
  private func detectProvider() -> (provider: String, bundleId: String)? {
    let running = NSWorkspace.shared.runningApplications
    for app in running {
      if let bid = app.bundleIdentifier, let provider = Self.dedicatedApps[bid] {
        return (provider, bid)
      }
    }
    for app in running {
      if let bid = app.bundleIdentifier, Self.browsers.contains(bid) {
        return ("generic", bid)  // mic-active browser → a meeting, provider unconfirmed
      }
    }
    return ("generic", "unknown")
  }

  private static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

  /// True if the system's default input device is currently running (captured by any process).
  private static func isMicrophoneActive() -> Bool {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMaster)
    let sysObj = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &deviceID) == noErr,
      deviceID != 0
    else { return false }

    var running = UInt32(0)
    var rsize = UInt32(MemoryLayout<UInt32>.size)
    var raddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMaster)
    guard AudioObjectGetPropertyData(deviceID, &raddr, 0, nil, &rsize, &running) == noErr else {
      return false
    }
    return running != 0
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Companion overlay — a SEPARATE, always-on-top, transparent, non-activating NSPanel that hosts
// its own Flutter engine (the `companionMain` entrypoint). It floats over other apps without
// stealing focus, joins all Spaces + fullscreen, and is draggable by its background.
// ─────────────────────────────────────────────────────────────────────────────
final class CompanionController: NSObject {
  private let commands = SinkHolder()
  private let mainMethod: FlutterMethodChannel
  private weak var mainWindow: NSWindow?

  private var panel: NSPanel?
  private var engine: FlutterEngine?
  private var incoming: FlutterMethodChannel?
  private var lastSnapshot: [String: Any]?
  private var expanded = false

  private static let posXKey = "notely.companion.x"
  private static let posYKey = "notely.companion.y"
  private static let pillSize = NSSize(width: 240, height: 54)
  private static let popoverSize = NSSize(width: 332, height: 430)

  init(messenger: FlutterBinaryMessenger, mainWindow: NSWindow) {
    self.mainWindow = mainWindow
    mainMethod = FlutterMethodChannel(name: "notely/companion", binaryMessenger: messenger)
    super.init()

    let eventChannel = FlutterEventChannel(
      name: "notely/companion/commands", binaryMessenger: messenger)
    eventChannel.setStreamHandler(commands)

    mainMethod.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "show":
        self.show()
        result(nil)
      case "hide":
        self.hide()
        result(nil)
      case "update":
        if let map = call.arguments as? [String: Any] { self.update(map) }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func show() {
    if panel == nil { build() }
    guard let panel = panel else { return }
    positionIfNeeded(panel)
    panel.orderFrontRegardless()  // show WITHOUT activating Notely / stealing focus
    if let snap = lastSnapshot { incoming?.invokeMethod("update", arguments: snap) }
  }

  private func hide() {
    panel?.orderOut(nil)
    // Reset to the collapsed pill for next time.
    if expanded { collapse() }
  }

  private func update(_ map: [String: Any]) {
    lastSnapshot = map
    incoming?.invokeMethod("update", arguments: map)
  }

  private func build() {
    let engine = FlutterEngine(
      name: "notely_companion", project: nil, allowHeadlessExecution: false)
    engine.run(withEntrypoint: "companionMain")
    self.engine = engine

    let vc = FlutterViewController(engine: engine, nibName: nil, bundle: nil)

    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: Self.pillSize),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered, defer: false)
    panel.contentViewController = vc
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    vc.view.wantsLayer = true
    vc.view.layer?.backgroundColor = NSColor.clear.cgColor
    vc.backgroundColor = .clear
    self.panel = panel

    incoming = FlutterMethodChannel(
      name: "notely/companion/incoming", binaryMessenger: engine.binaryMessenger)

    let outgoing = FlutterMethodChannel(
      name: "notely/companion/outgoing", binaryMessenger: engine.binaryMessenger)
    outgoing.setMethodCallHandler { [weak self] call, result in
      if call.method == "command", let cmd = call.arguments as? String {
        self?.handleCommand(cmd)
      }
      result(nil)
    }

    NotificationCenter.default.addObserver(
      self, selector: #selector(panelMoved(_:)),
      name: NSWindow.didMoveNotification, object: panel)
  }

  private func handleCommand(_ cmd: String) {
    switch cmd {
    case "expand":
      expand()
    case "collapse":
      collapse()
    case "pause", "resume", "stop", "openInNotely":
      commands.send(cmd)
      if cmd == "openInNotely" {
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      }
    default:
      break
    }
  }

  private func expand() {
    expanded = true
    resize(to: Self.popoverSize)
    incoming?.invokeMethod("setExpanded", arguments: true)
  }

  private func collapse() {
    expanded = false
    resize(to: Self.pillSize)
    incoming?.invokeMethod("setExpanded", arguments: false)
  }

  /// Resize keeping the TOP-LEFT corner fixed (windows grow downward from where the pill sits).
  private func resize(to size: NSSize) {
    guard let panel = panel else { return }
    let old = panel.frame
    let newOrigin = NSPoint(x: old.origin.x, y: old.maxY - size.height)
    panel.setFrame(NSRect(origin: newOrigin, size: size), display: true, animate: false)
  }

  @objc private func panelMoved(_ note: Notification) {
    guard let panel = panel else { return }
    let origin = panel.frame.origin
    UserDefaults.standard.set(Double(origin.x), forKey: Self.posXKey)
    UserDefaults.standard.set(Double(origin.y), forKey: Self.posYKey)
  }

  /// Restore the saved position, validating it against currently-connected displays so the
  /// overlay never ends up stranded off-screen after a monitor/resolution change.
  private func positionIfNeeded(_ panel: NSPanel) {
    let defaults = UserDefaults.standard
    let size = panel.frame.size
    if defaults.object(forKey: Self.posXKey) != nil {
      let x = CGFloat(defaults.double(forKey: Self.posXKey))
      let y = CGFloat(defaults.double(forKey: Self.posYKey))
      let candidate = NSRect(origin: NSPoint(x: x, y: y), size: size)
      if Self.isOnScreen(candidate) {
        panel.setFrame(candidate, display: false)
        return
      }
    }
    panel.setFrame(Self.defaultFrame(size: size), display: false)
  }

  private static func isOnScreen(_ frame: NSRect) -> Bool {
    for screen in NSScreen.screens where screen.visibleFrame.intersects(frame) {
      return true
    }
    return false
  }

  private static func defaultFrame(size: NSSize) -> NSRect {
    let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
    let margin: CGFloat = 24
    return NSRect(
      x: vf.maxX - size.width - margin,
      y: vf.minY + margin,
      width: size.width, height: size.height)
  }
}
