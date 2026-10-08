import 'dart:async';
import 'dart:developer' show log;

import 'package:flutter/rendering.dart' show PipelineOwner;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rhttp/rhttp.dart' as rhttp;

import 'app/app.dart';
import 'core/debug/frame_probe.dart';
import 'core/image/legacy_image_cache.dart';
import 'core/logging/crash_log.dart';
import 'core/network/rhttp_gate.dart';
import 'core/platform/native_warmup.dart';
import 'core/platform/platform_caps.dart';
import 'core/widget/widget_background.dart';
import 'package:path_provider/path_provider.dart';

/// Entrypoint: initializes the Rust transport (rhttp) before the first
/// widget builds, since every native Pixiv API, image, download and diagnostic
/// request funnels through the shared policy client. The ordinary login
/// WebView keeps its platform-owned browser transport.
///
/// `Rhttp.init` is idempotent. A failure here means the native librhttp.so
/// could not be loaded for this ABI — the app must not silently pretend
/// networking works, so the error propagates instead of being swallowed.
/// App binding: keeps the decoded image cache across background trips.
///
/// Android posts TRIM_MEMORY_UI_HIDDEN on every backgrounding — even when
/// the system is not under real pressure — and the stock
/// [PaintingBinding.handleMemoryPressure] answers it with
/// `imageCache.clear()`. Every decoded artwork is then evicted, so
/// returning to the app re-loads and re-fades every image. Glide-based
/// Android clients only trim on genuinely high pressure; matching them
/// means keeping the decoded cache and letting the OS reclaim the process
/// before the 256MB cap matters. The chain's `didHaveMemoryPressure`
/// observer fan-out is dropped with it — the observer list is private to
/// [WidgetsBinding] and nothing in the app or its plugins registers one.
class _ParfaitBinding extends WidgetsFlutterBinding {
  /// Replaces `WidgetsFlutterBinding.ensureInitialized` so the app runs on
  /// this binding. Call once, in main(), before anything touches binding
  /// state — the constructor registers itself as the singleton.
  static void ensureInitialized() {
    _ParfaitBinding();
  }

  // Replicates the stock chain with one distinction: decoded frames are
  // evicted only when the pressure signal arrives while the app is actually
  // resumed — the genuine low-memory case. TRIM_MEMORY_UI_HIDDEN arrives
  // hidden/paused on every backgrounding, where clearing the cache would
  // just force a re-decode-and-fade of every image on return. The
  // call-super contract is skipped intentionally — super would reintroduce
  // the unconditional clear this override exists to control.
  @override
  // ignore: must_call_super
  void handleMemoryPressure() {
    rootBundle.clear();
    imageCache.clearLiveImages();
    final lifecycle = SchedulerBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      imageCache.clear();
    }
  }

  // Frame-probe hooks: split each frame's UI-thread time by phase while the
  // probe records. When it does not, each hook is a plain super call.
  @override
  PipelineOwner createRootPipelineOwner() => ProbedRootPipelineOwner();

  @override
  void handleBeginFrame(Duration? rawTimeStamp) {
    FrameProbe.instance
      ..beginUiFrame()
      ..timePhase(UiPhase.animate, () => super.handleBeginFrame(rawTimeStamp));
  }

  @override
  void drawFrame() =>
      FrameProbe.instance.timePhase(UiPhase.draw, () => super.drawFrame());

  @override
  void handleDrawFrame() {
    FrameProbe.instance
      ..timePhase(UiPhase.frame, () => super.handleDrawFrame())
      ..endUiFrame(platformDispatcher.frameData.frameNumber);
  }
}

Future<void> main() async {
  _ParfaitBinding.ensureInitialized();
  // R3: local crash capture before anything else can throw — file logging
  // only, no remote telemetry.
  CrashLog.install(await getApplicationSupportDirectory());
  runZonedGuarded(() {
    unawaited(_run());
  }, CrashLog.record);
}

Future<void> _run() async {
  // High refresh is requested per-surface in MainActivity
  // (onFlutterSurfaceViewCreated → Surface.setFrameRate to the panel's top
  // rate): OEM builds throttle vsync *delivery* to ~60Hz a few seconds after
  // the last touch, and only a touch or an explicit surface frame-rate vote
  // restores it — return animations always play after the touch ends, so
  // they were the only animations stuck in the throttled window.
  // preferredDisplayModeId is deliberately NOT pinned: it neither stopped
  // the throttle nor is needed once the surface votes for its own rate.
  // Decoded-thumbnail cache: the default 100MB barely covers one retained
  // feed tab at physical-pixel decode sizes, so scrolling back after a
  // detail visit re-decodes evicted cards (visible stutter). 256MB keeps
  // the three retained feeds + a detail page resident.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 << 20;
  // Start the Rust transport without blocking the first frame: the network
  // policy waits on [RhttpGate.ready] before any request, so the UI (boot,
  // settings load, account restore) renders while rhttp initialises. The
  // original behaviour propagated init failure by throwing here; the gate
  // now surfaces it as a network error on the first request instead.
  RhttpGate.ready = rhttp.Rhttp.init();
  // A measurement package records from launch: cold start is a scenario
  // the probe page cannot be opened in time for. Stop it there.
  if (kPixivFrameProbe) FrameProbe.instance.start();
  runApp(const ProviderScope(child: ParfaitApp()));
  unawaited(_deleteLegacyImageCache());
  unawaited(_warmUpNativeChannels());
}

/// Pays the slow first calls of a few platform channels on a still screen
/// after startup, not inside the first detail page transition.
Future<void> _warmUpNativeChannels() async {
  if (!PlatformCaps.system().isAndroid) return;
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  await warmUpWhenQuiet(androidChannelWarmupSteps());
}

/// The image cache the worker replaced can hold hundreds of MB. It goes
/// once the first frame is on screen, off the startup path; every launch
/// checks again, which costs a few stats.
Future<void> _deleteLegacyImageCache() async {
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  final deleted = await deleteLegacyImageCache(
    temp: await getTemporaryDirectory(),
    support: await getApplicationSupportDirectory(),
  );
  if (deleted.isNotEmpty) log('deleted the legacy image cache: $deleted');
}

/// Headless entrypoint for the Android widget worker.
///
/// The Flutter engine resolves background entrypoints against the root
/// library, so the named function must live here; the implementation stays
/// in `core/widget/widget_background.dart`.
@pragma('vm:entry-point')
Future<void> widgetBackgroundMain() => runWidgetBackground();
