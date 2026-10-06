import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

/// Single probe point for platform capability branching.
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
  /// the Android app on a Linux host with it; it must be reset after use.
  @visibleForTesting
  static PlatformCaps? debugSystemOverride;

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
}

final platformCapsProvider = Provider<PlatformCaps>(
  (ref) => PlatformCaps.system(),
);
