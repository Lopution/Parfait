import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

/// Single probe point for platform capability branching across the five
/// first-class targets (Android, iOS, Windows, macOS, and Linux).
///
/// Business code never scatters `Platform.isWindows`; every selection site
/// reads this record and every provider can override it in tests — a Linux
/// `flutter test` therefore covers every platform's branches too.
class PlatformCaps {
  const PlatformCaps({
    this.isAndroid = false,
    this.isWindows = false,
    this.isLinux = false,
    this.isMacOS = false,
    this.isIOS = false,
  });

  factory PlatformCaps.system() =>
      debugSystemOverride ??
      PlatformCaps(
        isAndroid: Platform.isAndroid,
        isWindows: Platform.isWindows,
        isLinux: Platform.isLinux,
        isMacOS: Platform.isMacOS,
        isIOS: Platform.isIOS,
      );

  /// What [PlatformCaps.system] reports instead of the host, for widgets
  /// that read it without a provider scope. The UX review harness renders
  /// a device preset on any host with it; it must be reset after use.
  @visibleForTesting
  static PlatformCaps? debugSystemOverride;

  final bool isAndroid;
  final bool isWindows;
  final bool isLinux;
  final bool isMacOS;
  final bool isIOS;

  /// Mobile touch platforms (Android and iOS).
  bool get isMobile => isAndroid || isIOS;

  /// Apple platforms (iOS and macOS).
  bool get isApple => isIOS || isMacOS;

  /// Desktop windowing platforms (Windows, Linux and macOS).
  bool get isDesktop => isWindows || isLinux || isMacOS;

  /// Android MediaStore/SAF document semantics.
  bool get supportsMediaStore => isAndroid;

  /// iOS PHPhotoLibrary image/video saving semantics.
  bool get supportsPhotoLibrary => isIOS;

  /// Native tactile haptics feedback (Android and iOS).
  bool get supportsHaptics => isMobile;

  /// Desktop window geometry & frame management (`window_manager`).
  bool get supportsWindowManager => isDesktop;

  /// Desktop system tray integration.
  bool get supportsSystemTray => isDesktop;

  /// Desktop single-instance wakeup IPC.
  bool get supportsSingleInstance => isDesktop;

  /// macOS sandbox security-scoped file/directory bookmarks.
  bool get supportsSecurityScopedBookmarks => isMacOS;

  /// Embedded `flutter_inappwebview` support (Linux lacks a stable backend).
  bool get supportsInAppWebView => isAndroid || isIOS || isWindows || isMacOS;

  /// Custom URL scheme (`pixiv://`) OAuth / deep-link callback support.
  bool get supportsCustomSchemeCallback => isAndroid || isIOS || isMacOS;

  /// Loopback HTTP server (`127.0.0.1`) OAuth callback support.
  bool get supportsLoopbackCallback => isDesktop;

  /// APK side-load self-update (github flavor). Other platforms are
  /// store/asset managed — the updater reports storeManaged instead.
  bool get supportsSelfUpdater => isAndroid;

  /// Inbound deep-link / share routing across all five platforms.
  bool get supportsInboundIntents =>
      isAndroid || isIOS || isWindows || isMacOS || isLinux;
}

final platformCapsProvider = Provider<PlatformCaps>(
  (ref) => PlatformCaps.system(),
);
