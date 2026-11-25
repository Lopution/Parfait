import Cocoa
import FlutterMacOS
import ImageIO

class MainFlutterWindow: NSWindow {
  private(set) var lastPrimaryMouseEvent: NSEvent?

  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown, .leftMouseDragged:
      lastPrimaryMouseEvent = event
    case .leftMouseUp:
      lastPrimaryMouseEvent = nil
    default:
      break
    }
    super.sendEvent(event)
  }

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
    if #available(macOS 11.0, *) {
      let unifiedToolbar = NSToolbar(
        identifier: NSToolbar.Identifier("ParfaitUnifiedToolbar")
      )
      unifiedToolbar.showsBaselineSeparator = false
      unifiedToolbar.displayMode = .iconOnly
      self.toolbar = unifiedToolbar
      self.toolbarStyle = .unified
    }

    MacosDesktopWindowBridge.shared.register(
      window: self,
      messenger: flutterViewController.engine.binaryMessenger
    )
    MacosTrayBridge.shared.register(
      window: self,
      messenger: flutterViewController.engine.binaryMessenger
    )
    MacosSensitiveClipboardBridge.shared.register(
      messenger: flutterViewController.engine.binaryMessenger
    )
    MacosImageClipboardBridge.shared.register(
      messenger: flutterViewController.engine.binaryMessenger
    )
    MacosDesktopFileActionsBridge.shared.register(
      messenger: flutterViewController.engine.binaryMessenger
    )
    MacosFileDropBridge.shared.register(
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

  func withOptionalBookmarkAccess<T>(
    token: String?,
    onDenied: T,
    _ body: () -> T
  ) -> T {
    guard let token, !token.isEmpty else {
      return body()
    }
    guard let data = Data(base64Encoded: token) else {
      return onDenied
    }
    if var existing = activeAccess[token] {
      existing.count += 1
      activeAccess[token] = existing
      defer { releaseToken(token) }
      return body()
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
        return onDenied
      }
      activeAccess[token] = (url: resolvedUrl, count: 1)
      defer { releaseToken(token) }
      return body()
    } catch {
      return onDenied
    }
  }

  private func releaseToken(_ token: String) {
    if var existing = activeAccess[token] {
      existing.count -= 1
      if existing.count <= 0 {
        activeAccess.removeValue(forKey: token)
        existing.url.stopAccessingSecurityScopedResource()
      } else {
        activeAccess[token] = existing
      }
    }
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
  private var pendingLiveUris: [String] = []
  private var initialConsumed = false
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
        self.initialConsumed = true
        if let uri = self.initialUri {
          self.initialUri = nil
          result(Self.viewPayload(for: uri))
        } else {
          result(["action": "android.intent.action.MAIN"])
        }
        self.flushPendingLiveUrisIfReady()
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

  private func emit(uri: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard let sink = self.eventSink else {
        self.pendingLiveUris.append(uri)
        return
      }
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
  }

  private func flushPendingLiveUrisIfReady() {
    guard initialConsumed || initialUri == nil else { return }
    guard eventSink != nil, !pendingLiveUris.isEmpty else { return }
    let queued = pendingLiveUris
    pendingLiveUris.removeAll()
    for uri in queued {
      emit(uri: uri)
    }
  }

  private func recordIncoming(url: URL) -> Bool {
    guard Self.isSupportedUrl(url) else { return false }
    let uri = url.absoluteString
    if !initialConsumed && initialUri == nil && eventSink == nil {
      initialUri = uri
    } else if !initialConsumed && initialUri != nil {
      pendingLiveUris.append(uri)
    } else if eventSink != nil {
      emit(uri: uri)
    } else {
      pendingLiveUris.append(uri)
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
    flushPendingLiveUrisIfReady()
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
  private var preservedEditMenuItem: NSMenuItem?
  private var isTerminating = false
  private var pendingTerminateCompletion: (() -> Void)?

  func register(window: NSWindow, messenger: FlutterBinaryMessenger) {
    removeObservers()
    self.window = window
    captureEditMenuIfNeeded()
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didFinishLaunchingNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.captureEditMenuIfNeeded()
      }
    )

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
    observers.append(contentsOf: names.map { name in
      center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        self?.emitMetrics()
      }
    })
  }

  func requestApplicationTermination(
    reply: @escaping () -> Void
  ) -> NSApplication.TerminateReply {
    guard !isTerminating, let channel else {
      return .terminateNow
    }
    isTerminating = true
    var replied = false
    let timeoutWorkItem = DispatchWorkItem { [weak self] in
      guard !replied else { return }
      replied = true
      self?.pendingTerminateCompletion = nil
      reply()
    }
    let finish: () -> Void = { [weak self] in
      guard !replied else { return }
      replied = true
      timeoutWorkItem.cancel()
      self?.pendingTerminateCompletion = nil
      reply()
    }
    pendingTerminateCompletion = finish
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: timeoutWorkItem)
    channel.invokeMethod("applicationShouldTerminate", arguments: nil) { _ in
      DispatchQueue.main.async {
        finish()
      }
    }
    return .terminateLater
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
    case "restoreEditMenu":
      DispatchQueue.main.async { [weak self] in
        self?.restoreEditMenuIfNeeded()
      }
      result(nil)
    case "startDragging":
      let dragEvent: NSEvent?
      if let current = NSApp.currentEvent,
         current.type == .leftMouseDown || current.type == .leftMouseDragged {
        dragEvent = current
      } else {
        dragEvent = (window as? MainFlutterWindow)?.lastPrimaryMouseEvent
      }
      if let dragEvent {
        window.performDrag(with: dragEvent)
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

  private func captureEditMenuIfNeeded() {
    guard preservedEditMenuItem == nil, let mainMenu = NSApp.mainMenu else { return }
    for item in mainMenu.items {
      if let sub = item.submenu, isEditMenu(sub) {
        preservedEditMenuItem = item.copy() as? NSMenuItem
        break
      }
    }
  }

  private func isEditMenu(_ menu: NSMenu) -> Bool {
    return menu.items.contains { item in
      item.action == #selector(NSText.copy(_:)) ||
        item.action == #selector(NSText.paste(_:))
    }
  }

  private func restoreEditMenuIfNeeded() {
    guard let mainMenu = NSApp.mainMenu else { return }
    if mainMenu.items.contains(where: { $0.submenu.map(isEditMenu) ?? false }) {
      return
    }
    let item = (preservedEditMenuItem?.copy() as? NSMenuItem) ?? buildDefaultEditMenuItem()
    let insertIndex = min(2, mainMenu.items.count)
    mainMenu.insertItem(item, at: insertIndex)
  }

  private func buildDefaultEditMenuItem() -> NSMenuItem {
    let menu = NSMenu(title: "Edit")
    menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(redo)
    menu.addItem(.separator())
    menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let container = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    container.submenu = menu
    return container
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

final class MacosImageClipboardBridge {
  static let shared = MacosImageClipboardBridge()

  private let channelName = "parfait/image_clipboard"
  private static let maxReadBytes = 32 * 1024 * 1024
  private static let pngUti = "public.png" as CFString
  private var channel: FlutterMethodChannel?
  private var copySequence: UInt64 = 0

  func register(messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    channel = methodChannel
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(false)
        return
      }
      switch call.method {
      case "copyImageFile":
        guard
          let args = call.arguments as? [String: Any],
          let path = args["path"] as? String,
          !path.isEmpty
        else {
          result(
            FlutterError(
              code: "INVALID_ARGS",
              message: "Missing image file path",
              details: nil
            )
          )
          return
        }
        self.copySequence &+= 1
        let seq = self.copySequence
        DispatchQueue.global(qos: .userInitiated).async {
          let pngData = Self.preparePngDataFromFile(path: path)
          DispatchQueue.main.async {
            guard seq == self.copySequence, let png = pngData else {
              result(false)
              return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            result(pasteboard.setData(png, forType: .png))
          }
        }
      case "readImageToTempFile":
        guard
          let args = call.arguments as? [String: Any],
          let targetPath = args["targetPath"] as? String,
          !targetPath.isEmpty
        else {
          result(
            FlutterError(
              code: "INVALID_ARGS",
              message: "Missing targetPath",
              details: nil
            )
          )
          return
        }
        let pasteboard = NSPasteboard.general
        let rawPng = pasteboard.data(forType: .png)
        let rawTiff = (rawPng == nil || rawPng!.isEmpty)
          ? pasteboard.data(forType: .tiff)
          : nil
        guard
          (rawPng != nil && !rawPng!.isEmpty) ||
          (rawTiff != nil && !rawTiff!.isEmpty)
        else {
          result(false)
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let wrote = Self.writeClipboardImage(
            rawPng: rawPng,
            rawTiff: rawTiff,
            toPath: targetPath
          )
          DispatchQueue.main.async {
            result(wrote)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func preparePngDataFromFile(path: String) -> Data? {
    let url = URL(fileURLWithPath: path)
    guard
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      let fileSize = values.fileSize,
      fileSize > 0,
      fileSize <= maxReadBytes,
      let data = try? Data(contentsOf: url),
      !data.isEmpty,
      data.count <= maxReadBytes,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else {
      return nil
    }
    if let typeId = CGImageSourceGetType(source),
       CFStringCompare(typeId, pngUti, []) == .compareEqualTo {
      return data
    }
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      return nil
    }
    return encodeCgImageToPng(cgImage)
  }

  private static func writeClipboardImage(
    rawPng: Data?,
    rawTiff: Data?,
    toPath targetPath: String
  ) -> Bool {
    let pngData: Data?
    if let png = rawPng, !png.isEmpty, png.count <= maxReadBytes,
       let source = CGImageSourceCreateWithData(png as CFData, nil),
       CGImageSourceGetCount(source) > 0 {
      pngData = png
    } else if let tiff = rawTiff, !tiff.isEmpty,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
      pngData = encodeCgImageToPng(cgImage)
    } else {
      pngData = nil
    }
    guard let out = pngData, !out.isEmpty, out.count <= maxReadBytes else {
      return false
    }
    do {
      try out.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private static func encodeCgImageToPng(_ image: CGImage) -> Data? {
    let mutable = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        mutable as CFMutableData,
        pngUti,
        1,
        nil
      )
    else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }
    let data = mutable as Data
    guard !data.isEmpty, data.count <= maxReadBytes else {
      return nil
    }
    return data
  }
}

final class MacosDesktopFileActionsBridge {
  static let shared = MacosDesktopFileActionsBridge()

  private var channel: FlutterMethodChannel?

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "parfait/desktop_file_actions",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            !path.isEmpty else {
        result("failed")
        return
      }
      let bookmark = args["bookmark"] as? String
      switch call.method {
      case "openFile":
        let status = MacosBookmarkBridge.shared.withOptionalBookmarkAccess(
          token: bookmark,
          onDenied: "failed"
        ) { () -> String in
          guard FileManager.default.fileExists(atPath: path) else {
            return "notFound"
          }
          let url = URL(fileURLWithPath: path)
          return NSWorkspace.shared.open(url) ? "opened" : "failed"
        }
        result(status)
      case "showInFolder":
        let status = MacosBookmarkBridge.shared.withOptionalBookmarkAccess(
          token: bookmark,
          onDenied: "failed"
        ) { () -> String in
          guard FileManager.default.fileExists(atPath: path) else {
            return "notFound"
          }
          let url = URL(fileURLWithPath: path)
          NSWorkspace.shared.activateFileViewerSelecting([url])
          return "opened"
        }
        result(status)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }
}

private final class ParfaitFileDropOverlayView: NSView {
  var onEntered: (() -> Void)?
  var onExited: (() -> Void)?
  var onDropped: (([String]) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([.fileURL])
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Pass all regular pointer events straight through to FlutterView.
    return nil
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard !extractFilePaths(from: sender).isEmpty else {
      return []
    }
    onEntered?()
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    return extractFilePaths(from: sender).isEmpty ? [] : .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    onExited?()
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    onExited?()
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = extractFilePaths(from: sender)
    onExited?()
    guard !paths.isEmpty else {
      return false
    }
    onDropped?(paths)
    return true
  }

  private func extractFilePaths(from sender: NSDraggingInfo) -> [String] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
    ]
    guard let urls = sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self],
      options: options
    ) as? [URL] else {
      return []
    }
    return urls.compactMap { $0.isFileURL ? $0.path : nil }
  }
}

final class MacosFileDropBridge: NSObject, FlutterStreamHandler {
  static let shared = MacosFileDropBridge()

  private var eventChannel: FlutterEventChannel?
  private var eventSink: FlutterEventSink?
  private weak var dropView: ParfaitFileDropOverlayView?

  func register(window: NSWindow, messenger: FlutterBinaryMessenger) {
    let channel = FlutterEventChannel(
      name: "parfait/file_drop/events",
      binaryMessenger: messenger
    )
    channel.setStreamHandler(self)
    self.eventChannel = channel

    guard let contentView = window.contentView else { return }
    dropView?.removeFromSuperview()
    let overlay = ParfaitFileDropOverlayView(frame: contentView.bounds)
    overlay.autoresizingMask = [.width, .height]
    overlay.onEntered = { [weak self] in
      self?.emit(["type": "entered"])
    }
    overlay.onExited = { [weak self] in
      self?.emit(["type": "exited"])
    }
    overlay.onDropped = { [weak self] paths in
      self?.emit(["type": "dropped", "paths": paths])
    }
    contentView.addSubview(overlay)
    dropView = overlay
  }

  private func emit(_ payload: [String: Any]) {
    eventSink?(payload)
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }
}

final class MacosSensitiveClipboardBridge {
  static let shared = MacosSensitiveClipboardBridge()

  private static let concealedType = NSPasteboard.PasteboardType(
    "org.nspasteboard.ConcealedType"
  )
  private static let transientType = NSPasteboard.PasteboardType(
    "org.nspasteboard.TransientType"
  )
  private static let autoGeneratedType = NSPasteboard.PasteboardType(
    "org.nspasteboard.AutoGeneratedType"
  )

  private var channel: FlutterMethodChannel?

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "parfait/desktop_sensitive_clipboard",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call, result: result)
    }
    self.channel = channel
  }

  private func handleMethodCall(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "capabilities":
      result(["sensitiveMarkSupported": true])
    case "write":
      guard
        let arguments = call.arguments as? [String: Any],
        let text = arguments["text"] as? String,
        !text.isEmpty
      else {
        result(
          FlutterError(
            code: "invalid_argument",
            message: "text is required",
            details: nil
          )
        )
        return
      }
      let pasteboard = NSPasteboard.general
      pasteboard.declareTypes(
        [
          .string,
          Self.concealedType,
          Self.transientType,
          Self.autoGeneratedType,
        ],
        owner: nil
      )
      let emptyMarker = Data()
      let wroteText = pasteboard.setString(text, forType: .string)
      let wroteConcealed = pasteboard.setData(
        emptyMarker,
        forType: Self.concealedType
      )
      let wroteTransient = pasteboard.setData(
        emptyMarker,
        forType: Self.transientType
      )
      let wroteAutoGenerated = pasteboard.setData(
        emptyMarker,
        forType: Self.autoGeneratedType
      )
      guard wroteText && wroteConcealed && wroteTransient && wroteAutoGenerated else {
        pasteboard.clearContents()
        result(
          FlutterError(
            code: "clipboard_unavailable",
            message: "failed to write sensitive clipboard data",
            details: nil
          )
        )
        return
      }
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
