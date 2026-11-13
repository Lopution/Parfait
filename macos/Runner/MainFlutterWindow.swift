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
