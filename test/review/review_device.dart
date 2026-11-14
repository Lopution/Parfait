import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/core/platform/desktop_window_channel.dart';
import 'package:parfait/core/platform/platform_caps.dart';

/// A screen the review renders on: the panel in physical pixels, its
/// density, and the system bar and display cutout insets in logical
/// pixels (the cutout sits on the left, as on a phone turned left).
class ReviewDevice {
  const ReviewDevice({
    required this.physicalSize,
    required this.dpr,
    this.statusBar = 0,
    this.navigationBar = 0,
    this.cutout = 0,
    this.display,
    this.targetPlatform = TargetPlatform.android,
    this.platformCaps = const PlatformCaps(isAndroid: true),
    this.displayFeatures = const [],
    this.desktopMetrics,
    this.inputModality,
  });

  final Size physicalSize;
  final double dpr;
  final double statusBar;
  final double navigationBar;
  final double cutout;

  /// The whole display in logical pixels, which tells a phone from a
  /// larger screen (`AppBreakpoints.isPhoneDisplay`). Null: the window
  /// fills the display.
  final Size? display;

  /// The target platform this preset emulates.
  final TargetPlatform targetPlatform;

  /// The platform capability record this preset emulates.
  final PlatformCaps platformCaps;

  /// Physical or virtual display features (hinges / folds) reported on the view.
  final List<ui.DisplayFeature> displayFeatures;

  /// Desktop host chrome metrics (null uses default system frame / mobile).
  final DesktopWindowPlatformMetrics? desktopMetrics;

  /// Explicit initial input modality; defaults from [targetPlatform].
  final InputModality? inputModality;

  Size get displaySize => display ?? physicalSize / dpr;
}

/// The screens `PARFAIT_REVIEW_DEVICE` names. `phone` is the user's
/// device and the default: the panel size is measured; density and insets
/// are common values for a 1440p ROM until a probe report's `surface:`
/// line gives the real ones. The others sit in the window classes the
/// layout switches on (logical sizes in the comments).
const reviewDevices = <String, ReviewDevice>{
  // 411 x 896.
  'phone': ReviewDevice(
    physicalSize: Size(1440, 3136),
    dpr: 3.5,
    statusBar: 40,
    navigationBar: 16,
  ),
  // 896 x 411, the camera cutout on the left.
  'phone-landscape': ReviewDevice(
    physicalSize: Size(3136, 1440),
    dpr: 3.5,
    statusBar: 40,
    navigationBar: 16,
    cutout: 40,
  ),
  // 700 x 840, a book-style foldable opened.
  'foldable': ReviewDevice(
    physicalSize: Size(1840, 2208),
    dpr: 2.625,
    statusBar: 32,
    navigationBar: 16,
  ),
  // 800 x 1280.
  'tablet-portrait': ReviewDevice(
    physicalSize: Size(1600, 2560),
    dpr: 2,
    statusBar: 24,
    navigationBar: 16,
  ),
  // 1000 x 640, an 8-inch tablet turned.
  'tablet-small-landscape': ReviewDevice(
    physicalSize: Size(2000, 1280),
    dpr: 2,
    statusBar: 24,
    navigationBar: 16,
  ),
  // 1280 x 800.
  'tablet-landscape': ReviewDevice(
    physicalSize: Size(2560, 1600),
    dpr: 2,
    statusBar: 24,
    navigationBar: 16,
  ),
  // 1440 x 900, a desktop window on a 1920 x 1080 monitor: custom Windows bar.
  'desktop': ReviewDevice(
    physicalSize: Size(2880, 1800),
    dpr: 2,
    display: Size(1920, 1080),
    targetPlatform: TargetPlatform.windows,
    platformCaps: PlatformCaps(isWindows: true),
    inputModality: InputModality.pointer,
    desktopMetrics: DesktopWindowPlatformMetrics(usesSystemTitleBar: false),
  ),
  // 344 x 882, a book-style foldable's cover screen: narrower than any
  // phone, about 23:9.
  'fold-cover': ReviewDevice(
    physicalSize: Size(903, 2315),
    dpr: 2.625,
    statusBar: 32,
    navigationBar: 16,
  ),
  // 841 x 701, a book-style foldable opened and turned: wider than tall
  // but nearly square.
  'fold-landscape': ReviewDevice(
    physicalSize: Size(2208, 1840),
    dpr: 2.625,
    statusBar: 32,
    navigationBar: 16,
  ),
  // 360 x 374, a flip phone's outer screen running the app.
  'flip-cover': ReviewDevice(
    physicalSize: Size(1080, 1122),
    dpr: 3,
    statusBar: 24,
    navigationBar: 16,
  ),
  // 600 x 960, an 8-inch tablet upright: exactly the rail breakpoint.
  'tablet-small-portrait': ReviewDevice(
    physicalSize: Size(1200, 1920),
    dpr: 2,
    statusBar: 24,
    navigationBar: 16,
  ),
  // 924 x 1480, a 14-inch tablet upright.
  'tablet-large-portrait': ReviewDevice(
    physicalSize: Size(1848, 2960),
    dpr: 2,
    statusBar: 24,
    navigationBar: 16,
  ),
  // 1920 x 1080, a maximised desktop window: the extended rail.
  'desktop-large': ReviewDevice(
    physicalSize: Size(2880, 1620),
    dpr: 1.5,
    targetPlatform: TargetPlatform.windows,
    platformCaps: PlatformCaps(isWindows: true),
    inputModality: InputModality.pointer,
    desktopMetrics: DesktopWindowPlatformMetrics(usesSystemTitleBar: false),
  ),
  // 393 x 852, modern notched iPhone.
  'iphone': ReviewDevice(
    physicalSize: Size(1179, 2556),
    dpr: 3,
    statusBar: 59,
    navigationBar: 34,
    targetPlatform: TargetPlatform.iOS,
    platformCaps: PlatformCaps(isIOS: true),
    inputModality: InputModality.touch,
  ),
  // 820 x 1180, portrait touch iPad.
  'ipad': ReviewDevice(
    physicalSize: Size(1640, 2360),
    dpr: 2,
    statusBar: 24,
    navigationBar: 20,
    targetPlatform: TargetPlatform.iOS,
    platformCaps: PlatformCaps(isIOS: true),
    inputModality: InputModality.touch,
  ),
  // 884 x 740, book-style foldable opened vertically with 12dp hinge.
  'foldable-book': ReviewDevice(
    physicalSize: Size(2210, 1850),
    dpr: 2.5,
    statusBar: 28,
    navigationBar: 16,
    inputModality: InputModality.touch,
    displayFeatures: [
      ui.DisplayFeature(
        bounds: Rect.fromLTWH(436, 0, 12, 740),
        type: ui.DisplayFeatureType.hinge,
        state: ui.DisplayFeatureState.postureHalfOpened,
      ),
    ],
  ),
  // 884 x 740, half-opened foldable in horizontal tabletop posture.
  'foldable-tabletop': ReviewDevice(
    physicalSize: Size(2210, 1850),
    dpr: 2.5,
    statusBar: 28,
    navigationBar: 16,
    inputModality: InputModality.touch,
    displayFeatures: [
      ui.DisplayFeature(
        bounds: Rect.fromLTWH(0, 364, 884, 12),
        type: ui.DisplayFeatureType.hinge,
        state: ui.DisplayFeatureState.postureHalfOpened,
      ),
    ],
  ),
  // 1280 x 800, macOS desktop window with 78dp traffic light chrome inset.
  'macos': ReviewDevice(
    physicalSize: Size(2560, 1600),
    dpr: 2,
    display: Size(1440, 900),
    targetPlatform: TargetPlatform.macOS,
    platformCaps: PlatformCaps(isMacOS: true),
    inputModality: InputModality.pointer,
    desktopMetrics: DesktopWindowPlatformMetrics(
      usesSystemTitleBar: false,
      trafficLightWidth: 78,
      trafficLightHeight: 16,
    ),
  ),
  // 1280 x 800, Linux desktop window with integrated caption controls.
  'linux': ReviewDevice(
    physicalSize: Size(1920, 1200),
    dpr: 1.5,
    display: Size(1920, 1080),
    targetPlatform: TargetPlatform.linux,
    platformCaps: PlatformCaps(isLinux: true),
    inputModality: InputModality.pointer,
    desktopMetrics: DesktopWindowPlatformMetrics(usesSystemTitleBar: false),
  ),
};

/// The device of this run, from `PARFAIT_REVIEW_DEVICE` (default `phone`).
final reviewDeviceName =
    Platform.environment['PARFAIT_REVIEW_DEVICE'] ?? 'phone';
final ReviewDevice reviewDevice =
    reviewDevices[reviewDeviceName] ??
    _sizedDevice(reviewDeviceName) ??
    (throw ArgumentError.value(
      reviewDeviceName,
      'PARFAIT_REVIEW_DEVICE',
      'one of ${reviewDevices.keys.join(', ')}, or <width>x<height>',
    ));

/// `<width>x<height>` in logical pixels: a size sweep's window, filling
/// its display (so 740x360 is a phone and 1024x600 is not), at density 2
/// with phone-like system bars.
ReviewDevice? _sizedDevice(String name) {
  final match = RegExp(r'^(\d+)x(\d+)$').firstMatch(name);
  if (match == null) return null;
  final width = double.parse(match[1]!);
  final height = double.parse(match[2]!);
  return ReviewDevice(
    physicalSize: Size(width * 2, height * 2),
    dpr: 2,
    statusBar: 24,
    navigationBar: 16,
  );
}

/// Where fonts, PNGs, films and the manifest land: `PARFAIT_REVIEW_OUT`,
/// else `~/parfait-ux4-review`. Outside the repo, so review output never
/// becomes a commit.
final reviewOutDir =
    Platform.environment['PARFAIT_REVIEW_OUT'] ??
    '${Platform.environment['HOME']}/parfait-ux4-review';

/// Applies [device] (by default [reviewDevice]): panel and display size,
/// density, system bar insets, the [locale] as the system locale, font scale,
/// system [brightness] (the app's theme setting follows the system by
/// default), the engine's `accessibleNavigation` stuck on — the state
/// GKD leaves it in on the user's phone — and the device preset's platform,
/// for the framework and for widgets that read [PlatformCaps.system].
/// Shadows render as on the device: flutter_test otherwise draws every
/// elevation as a solid black outline. Whether touch exploration is on is
/// a provider, set by `ReviewWorld.open`.
void applyReviewDevice(
  WidgetTester tester, {
  required Locale locale,
  double textScale = 1.0,
  Brightness brightness = Brightness.light,
  ReviewDevice? device,
}) {
  final view = tester.view;
  device ??= reviewDevice;
  // In a tear-down, not [resetReviewDevice]: a view change gives the render
  // view a new root layer, and one made in the test body outlives it.
  addTearDown(view.reset);
  addTearDown(view.display.resetSize);
  view.physicalSize = device.physicalSize;
  view.devicePixelRatio = device.dpr;
  view.display.size = device.displaySize * view.display.devicePixelRatio;
  final insets = FakeViewPadding(
    left: device.cutout * device.dpr,
    top: device.statusBar * device.dpr,
    bottom: device.navigationBar * device.dpr,
  );
  view.padding = insets;
  view.viewPadding = insets;
  view.displayFeatures = device.displayFeatures;
  final dispatcher = tester.platformDispatcher;
  dispatcher.localesTestValue = [locale];
  dispatcher.localeTestValue = locale;
  dispatcher.textScaleFactorTestValue = textScale;
  dispatcher.platformBrightnessTestValue = brightness;
  dispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
    accessibleNavigation: true,
  );
  debugDefaultTargetPlatformOverride = device.targetPlatform;
  PlatformCaps.debugSystemOverride = device.platformCaps;
  debugDisableShadows = false;
}

void resetReviewDevice(WidgetTester tester) {
  final dispatcher = tester.platformDispatcher;
  dispatcher.clearLocalesTestValue();
  dispatcher.clearLocaleTestValue();
  dispatcher.clearTextScaleFactorTestValue();
  dispatcher.clearPlatformBrightnessTestValue();
  dispatcher.clearAccessibilityFeaturesTestValue();
  debugDefaultTargetPlatformOverride = null;
  PlatformCaps.debugSystemOverride = null;
  // The flutter_test default the end-of-test invariant check expects.
  debugDisableShadows = true;
}
