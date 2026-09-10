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
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
