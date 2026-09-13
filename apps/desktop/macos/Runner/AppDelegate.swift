import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Background runtime: keep meeting detection + the companion overlay alive when the user closes
  // the MAIN window. The process stays up (Dock/menu bar); reopening re-shows the main window.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      mainFlutterWindow?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
