import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    if let window = mainFlutterWindow as? MainFlutterWindow {
      return !window.closeToTray
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag, let window = mainFlutterWindow {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first, let window = mainFlutterWindow as? MainFlutterWindow else {
      return
    }
    window.handleDeepLink(url.absoluteString)
  }
}
