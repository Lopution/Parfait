import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rhttp/rhttp.dart' as rhttp;

import 'app/app.dart';
import 'core/network/rhttp_gate.dart';
import 'core/widget/widget_background.dart';

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
/// clients (PixShaft) only trim on genuinely high pressure; matching them
/// means keeping the decoded cache and letting the OS reclaim the process
/// before the 256MB cap matters. The chain's `didHaveMemoryPressure`
/// observer fan-out is dropped with it — the observer list is private to
/// [WidgetsBinding] and nothing in the app or its plugins registers one.
class _PixivFuncBinding extends WidgetsFlutterBinding {
  /// Replaces `WidgetsFlutterBinding.ensureInitialized` so the app runs on
  /// this binding. Call once, in main(), before anything touches binding
  /// state — the constructor registers itself as the singleton.
  static void ensureInitialized() {
    _PixivFuncBinding();
  }

  // Replicates the stock chain minus imageCache.clear(): rootBundle assets
  // and in-flight live image streams are cheap to rebuild; decoded frames
  // are not. The call-super contract is skipped intentionally — super would
  // reintroduce the clear this override exists to remove.
  @override
  // ignore: must_call_super
  void handleMemoryPressure() {
    rootBundle.clear();
    imageCache.clearLiveImages();
  }
}

Future<void> main() async {
  _PixivFuncBinding.ensureInitialized();
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
  runApp(const ProviderScope(child: PixivFuncApp()));
}

/// Headless entrypoint for the Android widget worker.
///
/// The Flutter engine resolves background entrypoints against the root
/// library, so the named function must live here; the implementation stays
/// in `core/widget/widget_background.dart`.
@pragma('vm:entry-point')
Future<void> widgetBackgroundMain() => runWidgetBackground();
