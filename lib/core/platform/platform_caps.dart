import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Single probe point for platform capability branching
/// (09-11-windows-desktop design §1).
///
/// Business code never scatters `Platform.isWindows`; every selection site
/// reads this record and every provider can override it in tests — a Linux
/// `flutter test` therefore covers the Windows branches too.
class PlatformCaps {
  const PlatformCaps({
    this.isAndroid = false,
    this.isWindows = false,
    this.isLinux = false,
    this.isMacOS = false,
    this.isIOS = false,
  });

  factory PlatformCaps.system() => PlatformCaps(
    isAndroid: Platform.isAndroid,
    isWindows: Platform.isWindows,
    isLinux: Platform.isLinux,
    isMacOS: Platform.isMacOS,
    isIOS: Platform.isIOS,
  );

  final bool isAndroid;
  final bool isWindows;
  final bool isLinux;
  final bool isMacOS;
  final bool isIOS;

  /// Desktop windowing platforms (Windows is the only supported desktop
  /// target; Linux/macOS are listed so dev hosts keep working in tests).
  bool get isDesktop => isWindows || isLinux || isMacOS;

  /// Android MediaStore/SAF document semantics.
  bool get supportsMediaStore => isAndroid;

  /// APK side-load self-update (github flavor). Desktop builds are
  /// store/asset managed — the updater reports storeManaged instead.
  bool get supportsSelfUpdater => isAndroid;

  /// ACTION_* inbound intents (deep-link share/receive).
  bool get supportsInboundIntents => isAndroid;

  /// The double-back-to-exit prompt only exists where a system back gesture
  /// can reach the root route.
  bool get supportsBackToExit => isAndroid;
}

final platformCapsProvider = Provider<PlatformCaps>(
  (ref) => PlatformCaps.system(),
);
