import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ParfaitIosBridge") {
      IosPhotosBridge.register(with: registrar.messenger())
      IosIntentBridge.register(with: registrar)
    }
  }
}

private enum IosPhotosBridge {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "parfait/ios_photos",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "saveImage" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            !path.isEmpty else {
        result(FlutterError(
          code: "ios_photo_invalid_argument",
          message: "Missing staged file path",
          details: nil
        ))
        return
      }
      let mimeType = (args["mimeType"] as? String) ?? "image/jpeg"
      let displayName = args["displayName"] as? String
      saveToPhotoLibrary(
        path: path,
        mimeType: mimeType,
        displayName: displayName,
        result: result
      )
    }
  }

  private static func saveToPhotoLibrary(
    path: String,
    mimeType: String,
    displayName: String?,
    result: @escaping FlutterResult
  ) {
    let fileURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      result(FlutterError(
        code: "ios_photo_not_found",
        message: "Staged file does not exist",
        details: nil
      ))
      return
    }

    ensureAddAuthorization { authorized in
      guard authorized else {
        result(FlutterError(
          code: "ios_photo_permission_denied",
          message: "Photo Library add-only permission was denied",
          details: nil
        ))
        return
      }

      var createdLocalIdentifier: String?
      PHPhotoLibrary.shared().performChanges({
        let options = PHAssetResourceCreationOptions()
        if let displayName, !displayName.isEmpty {
          options.originalFilename = displayName
        }
        let request = PHAssetCreationRequest.forAsset()
        let resourceType: PHAssetResourceType =
          mimeType.hasPrefix("video/") ? .video : .photo
        request.addResource(with: resourceType, fileURL: fileURL, options: options)
        createdLocalIdentifier = request.placeholderForCreatedAsset?.localIdentifier
      }) { success, error in
        DispatchQueue.main.async {
          if success, let localId = createdLocalIdentifier, !localId.isEmpty {
            result("ph:///\(localId)")
          } else {
            result(FlutterError(
              code: "ios_photo_save_failed",
              message: error?.localizedDescription ?? "Failed to save asset to Photo Library",
              details: nil
            ))
          }
        }
      }
    }
  }

  private static func ensureAddAuthorization(completion: @escaping (Bool) -> Void) {
    let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    switch current {
    case .authorized, .limited:
      completion(true)
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        DispatchQueue.main.async {
          completion(status == .authorized || status == .limited)
        }
      }
    default:
      completion(false)
    }
  }
}

final class IosIntentBridge:
  NSObject,
  FlutterPlugin,
  FlutterSceneLifeCycleDelegate,
  FlutterStreamHandler
{
  static let shared = IosIntentBridge()
  private static let supportedSchemes: Set<String> = ["parfait", "pixiv"]

  private var initialUri: String?
  private var eventSink: FlutterEventSink?
  private var registered = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let bridge = IosIntentBridge.shared
    registrar.addSceneDelegate(bridge)
    registrar.addApplicationDelegate(bridge)
    guard !bridge.registered else { return }
    bridge.registered = true

    let methodChannel = FlutterMethodChannel(
      name: "parfait/android_intents",
      binaryMessenger: registrar.messenger()
    )
    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getInitialIntent":
        if let uri = bridge.initialUri {
          bridge.initialUri = nil
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
      binaryMessenger: registrar.messenger()
    )
    eventChannel.setStreamHandler(bridge)
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

  @objc(scene:willConnectToSession:options:)
  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let contexts = connectionOptions?.urlContexts else { return false }
    var handled = false
    for context in contexts {
      if recordIncoming(url: context.url) {
        handled = true
      }
    }
    return handled
  }

  @objc(scene:openURLContexts:)
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    var handled = false
    for context in URLContexts {
      if recordIncoming(url: context.url) {
        handled = true
      }
    }
    return handled
  }

  @objc(application:openURL:options:)
  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return recordIncoming(url: url)
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
