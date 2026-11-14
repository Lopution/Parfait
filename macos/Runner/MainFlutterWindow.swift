import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // The desktop default and floor from lib/app/window/window_geometry.dart
    // (1280x800, 480x640); the saved place replaces this before the first
    // frame, as on Windows.
    self.setContentSize(NSSize(width: 1280, height: 800))
    self.contentMinSize = NSSize(width: 480, height: 640)
    self.center()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    MacosBookmarkBridge.shared.register(
      messenger: flutterViewController.engine.binaryMessenger
    )
    MacosIntentBridge.shared.register(
      messenger: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()

    self.styleMask.insert(.fullSizeContentView)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden

    MacosDesktopWindowBridge.shared.register(
      window: self,
      messenger: flutterViewController.engine.binaryMessenger
    )
    MacosTrayBridge.shared.register(
      window: self,
      messenger: flutterViewController.engine.binaryMessenger
    )
  }
}

final class MacosBookmarkBridge {
  static let shared = MacosBookmarkBridge()

  private var activeAccess: [String: (url: URL, count: Int)] = [:]

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "parfait/macos_bookmarks",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "saveBookmark":
        self.handleSaveBookmark(call.arguments, result: result)
      case "startAccess":
        self.handleStartAccess(call.arguments, result: result)
      case "stopAccess":
        self.handleStopAccess(call.arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func handleSaveBookmark(_ arguments: Any?, result: FlutterResult) {
    guard let args = arguments as? [String: Any],
          let path = args["path"] as? String,
          !path.isEmpty else {
      result(FlutterError(
        code: "macos_bookmark_invalid_argument",
        message: "Missing directory path",
        details: nil
      ))
      return
    }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    do {
      let data = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      result(data.base64EncodedString())
    } catch {
      result(FlutterError(
        code: "macos_bookmark_save_failed",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func handleStartAccess(_ arguments: Any?, result: FlutterResult) {
    guard let args = arguments as? [String: Any],
          let token = args["bookmark"] as? String,
          !token.isEmpty,
          let data = Data(base64Encoded: token) else {
      result(FlutterError(
        code: "macos_bookmark_invalid_argument",
        message: "Missing or invalid security-scoped bookmark token",
        details: nil
      ))
      return
    }
    if var existing = activeAccess[token] {
      existing.count += 1
      activeAccess[token] = existing
      result(existing.url.path)
      return
    }
    do {
      var isStale = false
      let resolvedUrl = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      guard resolvedUrl.startAccessingSecurityScopedResource() else {
        result(FlutterError(
          code: "macos_bookmark_access_denied",
          message: "Unable to start security-scoped resource access",
          details: nil
        ))
        return
      }
      activeAccess[token] = (url: resolvedUrl, count: 1)
      result(resolvedUrl.path)
    } catch {
      result(FlutterError(
        code: "macos_bookmark_resolve_failed",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func handleStopAccess(_ arguments: Any?, result: FlutterResult) {
    guard let args = arguments as? [String: Any],
          let token = args["bookmark"] as? String,
          !token.isEmpty else {
      result(nil)
      return
    }
    if var existing = activeAccess[token] {
      existing.count -= 1
      if existing.count <= 0 {
        activeAccess.removeValue(forKey: token)
        existing.url.stopAccessingSecurityScopedResource()
      } else {
        activeAccess[token] = existing
      }
    }
    result(nil)
  }
}

final class MacosIntentBridge:
  NSObject,
  FlutterAppLifecycleDelegate,
  FlutterStreamHandler
{
  static let shared = MacosIntentBridge()
  private static let supportedSchemes: Set<String> = ["parfait", "pixiv"]

  private var initialUri: String?
  private var eventSink: FlutterEventSink?
  private var registered = false

  func register(messenger: FlutterBinaryMessenger) {
    guard !registered else { return }
    registered = true

    let methodChannel = FlutterMethodChannel(
      name: "parfait/android_intents",
      binaryMessenger: messenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "getInitialIntent":
        if let uri = self.initialUri {
          self.initialUri = nil
          result(Self.viewPayload(for: uri))
        } else {
          result(["action": "android.intent.action.MAIN"])
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: "parfait/android_intents/events",
      binaryMessenger: messenger
    )
    eventChannel.setStreamHandler(self)
  }

  private static func isSupportedUrl(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return supportedSchemes.contains(scheme)
  }

  private static func viewPayload(for uri: String) -> [String: Any] {
    return [
      "action": "android.intent.action.VIEW",
      "uri": uri,
    ]
  }

  private func recordIncoming(url: URL) -> Bool {
    guard Self.isSupportedUrl(url) else { return false }
    let uri = url.absoluteString
    if let sink = eventSink {
      DispatchQueue.main.async {
        if let window = (NSApp.delegate as? FlutterAppDelegate)?.mainFlutterWindow
          ?? NSApp.windows.first(where: { $0 is MainFlutterWindow }) {
          if window.isMiniaturized {
            window.deminiaturize(nil)
          }
          window.makeKeyAndOrderFront(nil)
          NSApp.activate(ignoringOtherApps: true)
        }
        sink(Self.viewPayload(for: uri))
      }
    } else {
      initialUri = uri
    }
    return true
  }

  @objc(handleOpenURLs:)
  func handleOpen(_ urls: [URL]) -> Bool {
    var handled = false
    for url in urls {
      if recordIncoming(url: url) {
        handled = true
      }
    }
    return handled
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }
}

final class MacosDesktopWindowBridge: NSObject {
  static let shared = MacosDesktopWindowBridge()

  private weak var window: NSWindow?
  private var channel: FlutterMethodChannel?
  private var observers: [NSObjectProtocol] = []

  func register(window: NSWindow, messenger: FlutterBinaryMessenger) {
    removeObservers()
    self.window = window

    let channel = FlutterMethodChannel(
      name: "parfait/desktop_window",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call, result: result)
    }
    self.channel = channel

    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      NSWindow.didResizeNotification,
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
    ]
    observers = names.map { name in
      center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        self?.emitMetrics()
      }
    }
  }

  private func removeObservers() {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
    observers.removeAll()
  }

  private func buildMetrics(for window: NSWindow) -> [String: Any] {
    let isFullScreen = window.styleMask.contains(.fullScreen)
    var trafficLightWidth = 0.0
    var trafficLightHeight = 0.0

    if !isFullScreen {
      let titleBarDelta = max(0.0, Double(window.frame.height - window.contentLayoutRect.height))
      trafficLightHeight = max(32.0, titleBarDelta)
      if let zoomButton = window.standardWindowButton(.zoomButton),
         let contentView = window.contentView {
        let rectInContent = contentView.convert(zoomButton.bounds, from: zoomButton)
        if rectInContent.maxX > 0 && rectInContent.minX < contentView.bounds.width / 2 {
          trafficLightWidth = max(68.0, Double(rectInContent.maxX) + 12.0)
        } else {
          trafficLightWidth = 78.0
        }
      } else {
        trafficLightWidth = 78.0
      }
    }

    return [
      "isWayland": false,
      "usesSystemTitleBar": false,
      "isFullScreen": isFullScreen,
      "isMaximized": window.isZoomed,
      "isActive": window.isKeyWindow,
      "trafficLightWidth": trafficLightWidth,
      "trafficLightHeight": trafficLightHeight,
      "hoveredButton": "",
      "pressedButton": "",
    ]
  }

  private func emitMetrics() {
    guard let window, let channel else { return }
    channel.invokeMethod("metricsChanged", arguments: buildMetrics(for: window))
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let window else {
      result(nil)
      return
    }
    switch call.method {
    case "getMetrics":
      result(buildMetrics(for: window))
    case "setTitleBarMetrics":
      result(nil)
    case "minimize":
      window.miniaturize(nil)
      result(nil)
    case "toggleMaximize":
      window.zoom(nil)
      result(nil)
    case "close":
      window.performClose(nil)
      result(nil)
    case "toggleFullScreen":
      window.toggleFullScreen(nil)
      result(nil)
    case "startDragging":
      if let event = NSApp.currentEvent {
        window.performDrag(with: event)
      }
      result(nil)
    case "titleBarDoubleClick":
      let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
      switch action {
      case "Minimize":
        window.miniaturize(nil)
      case "None":
        break
      default:
        window.zoom(nil)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

final class MacosTrayBridge: NSObject {
  static let shared = MacosTrayBridge()

  private weak var window: NSWindow?
  private var channel: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private var showWindowItem: NSMenuItem?
  private var downloadsItem: NSMenuItem?
  private var quitItem: NSMenuItem?

  private var tooltip = "Parfait"
  private var showWindowTitle = "Show Window"
  private var downloadsTitle = "Downloads"
  private var quitTitle = "Quit"

  func register(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    let channel = FlutterMethodChannel(
      name: "parfait/tray",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call, result: result)
    }
    self.channel = channel
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(true)
    case "initialize":
      updateStoredLabels(from: call.arguments)
      ensureStatusItem()
      result(nil)
    case "updateLabels":
      updateStoredLabels(from: call.arguments)
      applyLabels()
      result(nil)
    case "dispose":
      removeStatusItem()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func updateStoredLabels(from arguments: Any?) {
    guard let map = arguments as? [String: Any] else { return }
    if let value = map["tooltip"] as? String, !value.isEmpty {
      tooltip = value
    }
    if let value = map["showWindow"] as? String, !value.isEmpty {
      showWindowTitle = value
    }
    if let value = map["downloads"] as? String, !value.isEmpty {
      downloadsTitle = value
    }
    if let value = map["quit"] as? String, !value.isEmpty {
      quitTitle = value
    }
  }

  private func ensureStatusItem() {
    if statusItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      if let appIcon = NSApp.applicationIconImage?.copy() as? NSImage {
        appIcon.size = NSSize(width: 18, height: 18)
        item.button?.image = appIcon
      }

      let menu = NSMenu()
      let show = NSMenuItem(
        title: showWindowTitle,
        action: #selector(handleShowWindow),
        keyEquivalent: ""
      )
      show.target = self
      menu.addItem(show)

      let downloads = NSMenuItem(
        title: downloadsTitle,
        action: #selector(handleOpenDownloads),
        keyEquivalent: ""
      )
      downloads.target = self
      menu.addItem(downloads)

      menu.addItem(NSMenuItem.separator())

      let quit = NSMenuItem(
        title: quitTitle,
        action: #selector(handleQuit),
        keyEquivalent: ""
      )
      quit.target = self
      menu.addItem(quit)

      item.menu = menu
      statusItem = item
      showWindowItem = show
      downloadsItem = downloads
      quitItem = quit
    }
    applyLabels()
  }

  private func applyLabels() {
    statusItem?.button?.toolTip = tooltip
    showWindowItem?.title = showWindowTitle
    downloadsItem?.title = downloadsTitle
    quitItem?.title = quitTitle
  }

  private func removeStatusItem() {
    if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
      showWindowItem = nil
      downloadsItem = nil
      quitItem = nil
    }
  }

  private func restoreWindow() {
    guard let window else { return }
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func handleShowWindow() {
    restoreWindow()
    channel?.invokeMethod("onTrayAction", arguments: "showWindow")
  }

  @objc private func handleOpenDownloads() {
    restoreWindow()
    channel?.invokeMethod("onTrayAction", arguments: "openDownloads")
  }

  @objc private func handleQuit() {
    channel?.invokeMethod("onTrayAction", arguments: "quit")
  }
}
