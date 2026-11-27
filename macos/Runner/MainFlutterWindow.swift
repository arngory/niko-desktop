import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var windowChannel: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private var pendingDeepLinks: [String] = []
  var closeToTray: Bool = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.title = "Niko"
    self.minSize = NSSize(width: 420, height: 600)
    self.setContentSize(NSSize(width: 1280, height: 720))
    self.center()
    self.delegate = self

    RegisterGeneratedPlugins(registry: flutterViewController)
    setupWindowChannel(binaryMessenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  private func setupWindowChannel(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "niko/window", binaryMessenger: binaryMessenger)
    self.windowChannel = channel

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "setDark":
        let dark = (call.arguments as? Bool) ?? true
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        self.appearance = appearance
        result(nil)

      case "setCloseToTray":
        self.closeToTray = (call.arguments as? Bool) ?? false
        result(nil)

      case "showWindow":
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        result(nil)

      case "hideWindow":
        self.orderOut(nil)
        result(nil)

      case "closeWindow":
        self.closeToTray = false
        NSApp.terminate(nil)
        result(nil)

      case "updateTray":
        if let args = call.arguments as? [String: Any] {
          self.updateTray(args: args)
        }
        result(nil)

      case "notify":
        if let args = call.arguments as? [String: Any] {
          let title = (args["title"] as? String) ?? "Niko"
          let body = (args["body"] as? String) ?? ""
          self.postNotification(title: title, body: body)
          result(true)
        } else {
          result(false)
        }

      case "pickFile":
        let args = call.arguments as? [String: Any]
        let title = (args?["title"] as? String) ?? "Open file"
        let extensions = (args?["extensions"] as? [String]) ?? []
        result(self.openFilePanel(title: title, extensions: extensions))

      case "pickDirectory":
        let args = call.arguments as? [String: Any]
        let title = (args?["title"] as? String) ?? "Choose folder"
        result(self.openDirectoryPanel(title: title))

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    if !pendingDeepLinks.isEmpty {
      let queued = pendingDeepLinks
      pendingDeepLinks.removeAll()
      for link in queued {
        channel.invokeMethod("deepLink", arguments: link)
      }
    }
  }

  func handleDeepLink(_ url: String) {
    self.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if let channel = windowChannel {
      channel.invokeMethod("deepLink", arguments: url)
    } else {
      pendingDeepLinks.append(url)
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if closeToTray {
      self.orderOut(nil)
      return false
    }
    return true
  }

  private func ensureStatusItem() -> NSStatusItem {
    if let existing = statusItem {
      return existing
    }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    return item
  }

  private func updateTray(args: [String: Any]) {
    let connected = (args["connected"] as? Bool) ?? false
    let status = (args["status"] as? String) ?? ""
    let profile = (args["profile"] as? String) ?? ""
    let toggleLabel = (args["toggleLabel"] as? String) ?? (connected ? "Disconnect" : "Connect")
    let openLabel = (args["openLabel"] as? String) ?? "Open Niko"
    let quitLabel = (args["quitLabel"] as? String) ?? "Quit"

    let item = ensureStatusItem()
    if let button = item.button {
      if #available(macOS 11.0, *),
         let symbol = NSImage(
           systemSymbolName: connected ? "shield.fill" : "shield",
           accessibilityDescription: "Niko"
         ) {
        symbol.isTemplate = true
        button.image = symbol
        button.title = ""
      } else {
        button.title = connected ? "Niko*" : "Niko"
      }
      button.toolTip = profile.isEmpty ? "Niko — \(status)" : "Niko — \(status) (\(profile))"
    }

    let menu = NSMenu()
    if !status.isEmpty {
      let header = profile.isEmpty ? status : "\(status) — \(profile)"
      let statusItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
      statusItem.isEnabled = false
      menu.addItem(statusItem)
      menu.addItem(NSMenuItem.separator())
    }

    let toggleItem = NSMenuItem(title: toggleLabel, action: #selector(onTrayToggle), keyEquivalent: "")
    toggleItem.target = self
    menu.addItem(toggleItem)

    let openItem = NSMenuItem(title: openLabel, action: #selector(onTrayOpen), keyEquivalent: "")
    openItem.target = self
    menu.addItem(openItem)

    menu.addItem(NSMenuItem.separator())

    let quitItem = NSMenuItem(title: quitLabel, action: #selector(onTrayQuit), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    item.menu = menu
  }

  @objc private func onTrayToggle() {
    windowChannel?.invokeMethod("trayAction", arguments: "toggle")
  }

  @objc private func onTrayOpen() {
    self.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    windowChannel?.invokeMethod("trayAction", arguments: "open")
  }

  @objc private func onTrayQuit() {
    windowChannel?.invokeMethod("trayAction", arguments: "quit")
  }

  private func postNotification(title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
      )
      center.add(request, withCompletionHandler: nil)
    }
  }

  private func openFilePanel(title: String, extensions: [String]) -> String? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    let cleaned = extensions
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
      .filter { !$0.isEmpty }
    if !cleaned.isEmpty {
      panel.allowedFileTypes = cleaned
    }
    return panel.runModal() == .OK ? panel.url?.path : nil
  }

  private func openDirectoryPanel(title: String) -> String? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url?.path : nil
  }
}
