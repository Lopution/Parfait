import CoreHaptics
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
      IosHapticsBridge.register(with: registrar.messenger())
      IosIntentBridge.register(with: registrar)
    }
  }
}

private enum IosHapticsBridge {
  private static let channelName = "parfait/haptics"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "capabilities":
        result([
          "tier": supportsTapticEngine() ? "predefined" : "none",
          "systemOff": false,
        ])
      case "play":
        guard let args = call.arguments as? [String: Any],
              let role = args["role"] as? String,
              !role.isEmpty else {
          result(FlutterError(
            code: "haptics_invalid_argument",
            message: "Missing haptic role",
            details: nil
          ))
          return
        }
        guard supportsTapticEngine(),
              let feedbackType = notificationFeedbackType(for: role) else {
          result(nil)
          return
        }
        let emit = {
          let generator = UINotificationFeedbackGenerator()
          generator.prepare()
          generator.notificationOccurred(feedbackType)
          result(nil)
        }
        if Thread.isMainThread {
          emit()
        } else {
          DispatchQueue.main.async(execute: emit)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func supportsTapticEngine() -> Bool {
    return UIDevice.current.userInterfaceIdiom != .pad &&
      CHHapticEngine.capabilitiesForHardware().supportsHaptics
  }

  private static func notificationFeedbackType(
    for role: String
  ) -> UINotificationFeedbackGenerator.FeedbackType? {
    switch role {
    case "success":
      return .success
    case "warning":
      return .warning
    case "error":
      return .error
    default:
      return nil
    }
  }
}

private enum IosPhotosBridge {
  private static let albumQueue = DispatchQueue(
    label: "com.parfait.ios_photos.album"
  )

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
      let rawAlbum = (args["album"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let album = (rawAlbum?.isEmpty == false) ? rawAlbum : nil
      saveToPhotoLibrary(
        path: path,
        mimeType: mimeType,
        displayName: displayName,
        album: album,
        result: result
      )
    }
  }

  private static func saveToPhotoLibrary(
    path: String,
    mimeType: String,
    displayName: String?,
    album: String?,
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

    ensureAuthorization(requiresAlbumWrite: album != nil) { status in
      guard status == .authorized || status == .limited else {
        result(FlutterError(
          code: "ios_photo_permission_denied",
          message: album != nil
            ? "Photo Library read-write permission was denied"
            : "Photo Library add-only permission was denied",
          details: nil
        ))
        return
      }

      albumQueue.async {
        var createdLocalIdentifier: String?
        var createSuccess = false
        var createError: Error?
        let createSemaphore = DispatchSemaphore(value: 0)
        PHPhotoLibrary.shared().performChanges({
          let options = PHAssetResourceCreationOptions()
          if let displayName, !displayName.isEmpty {
            options.originalFilename = displayName
          }
          let request = PHAssetCreationRequest.forAsset()
          let resourceType: PHAssetResourceType =
            mimeType.hasPrefix("video/") ? .video : .photo
          request.addResource(
            with: resourceType,
            fileURL: fileURL,
            options: options
          )
          createdLocalIdentifier =
            request.placeholderForCreatedAsset?.localIdentifier
        }) { success, error in
          createSuccess = success
          createError = error
          createSemaphore.signal()
        }
        createSemaphore.wait()

        guard createSuccess,
              let localId = createdLocalIdentifier,
              !localId.isEmpty else {
          let code = isNoSpaceError(createError)
            ? "ios_photo_no_space"
            : "ios_photo_save_failed"
          DispatchQueue.main.async {
            result(FlutterError(
              code: code,
              message: createError?.localizedDescription
                ?? "Failed to save asset to Photo Library",
              details: nil
            ))
          }
          return
        }

        // Only place into a named album under full `.authorized` access so
        // `.limited` photo selection still saves cleanly into Recents without
        // rolling back the asset creation transaction.
        if status == .authorized, let album, !album.isEmpty {
          let fetched = PHAsset.fetchAssets(
            withLocalIdentifiers: [localId],
            options: nil
          )
          if let asset = fetched.firstObject {
            let albumSemaphore = DispatchSemaphore(value: 0)
            PHPhotoLibrary.shared().performChanges({
              if let existing = findAlbum(named: album),
                 let albumRequest = PHAssetCollectionChangeRequest(for: existing) {
                albumRequest.addAssets([asset] as NSArray)
              } else {
                let albumRequest =
                  PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                    withTitle: album
                  )
                albumRequest.addAssets([asset] as NSArray)
              }
            }) { _, _ in
              albumSemaphore.signal()
            }
            albumSemaphore.wait()
          }
        }

        DispatchQueue.main.async {
          result("ph:///\(localId)")
        }
      }
    }
  }

  private static func isNoSpaceError(_ error: Error?) -> Bool {
    guard let nsError = error as NSError? else { return false }
    if nsError.domain == NSCocoaErrorDomain &&
        nsError.code == NSFileWriteOutOfSpaceError {
      return true
    }
    if nsError.domain == NSPOSIXErrorDomain &&
        nsError.code == Int(ENOSPC) {
      return true
    }
    if nsError.domain == PHPhotosErrorDomain &&
        nsError.code == PHPhotosError.Code.notEnoughSpace.rawValue {
      return true
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      return isNoSpaceError(underlying)
    }
    return false
  }

  private static func findAlbum(named title: String) -> PHAssetCollection? {
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "title = %@", title)
    let collections = PHAssetCollection.fetchAssetCollections(
      with: .album,
      subtype: .albumRegular,
      options: options
    )
    var found: PHAssetCollection?
    collections.enumerateObjects { collection, _, stop in
      if collection.canPerform(.addContent) {
        found = collection
        stop.pointee = true
      }
    }
    return found
  }

  private static func ensureAuthorization(
    requiresAlbumWrite: Bool,
    completion: @escaping (PHAuthorizationStatus) -> Void
  ) {
    let accessLevel: PHAccessLevel = requiresAlbumWrite ? .readWrite : .addOnly
    let current = PHPhotoLibrary.authorizationStatus(for: accessLevel)
    switch current {
    case .authorized, .limited:
      completion(current)
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: accessLevel) { status in
        DispatchQueue.main.async {
          completion(status)
        }
      }
    default:
      completion(current)
    }
  }
}

final class IosIntentBridge:
  NSObject,
  FlutterPlugin,
  FlutterSceneLifeCycleDelegate,
  FlutterStreamHandler
{
  private static let supportedSchemes: Set<String> = ["parfait", "pixiv"]

  private var initialUri: String?
  private var pendingLiveUris: [String] = []
  private var initialConsumed = false
  private var eventSink: FlutterEventSink?

  static func register(with registrar: FlutterPluginRegistrar) {
    let bridge = IosIntentBridge()
    registrar.addSceneDelegate(bridge)
    registrar.addApplicationDelegate(bridge)

    let methodChannel = FlutterMethodChannel(
      name: "parfait/android_intents",
      binaryMessenger: registrar.messenger()
    )
    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getInitialIntent":
        bridge.initialConsumed = true
        if let uri = bridge.initialUri {
          bridge.initialUri = nil
          result(Self.viewPayload(for: uri))
        } else {
          result(["action": "android.intent.action.MAIN"])
        }
        bridge.flushPendingLiveUrisIfReady()
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

  private func emit(uri: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard let sink = self.eventSink else {
        self.pendingLiveUris.append(uri)
        return
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
    flushPendingLiveUrisIfReady()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }
}
