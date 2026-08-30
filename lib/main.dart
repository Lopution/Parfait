import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rhttp/rhttp.dart' as rhttp;

import 'app/app.dart';
import 'core/widget/widget_background.dart';

/// Entrypoint: initializes the Rust transport (rhttp) before the first
/// widget builds, since every production network exit (API / image /
/// download / probe / login interception) funnels through it.
///
/// `Rhttp.init` is idempotent. A failure here means the native librhttp.so
/// could not be loaded for this ABI — the app must not silently pretend
/// networking works, so the error propagates instead of being swallowed.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await rhttp.Rhttp.init();
  runApp(const ProviderScope(child: PixivFuncApp()));
}

/// Headless entrypoint for the Android widget worker.
///
/// The Flutter engine resolves background entrypoints against the root
/// library, so the named function must live here; the implementation stays
/// in `core/widget/widget_background.dart`.
@pragma('vm:entry-point')
Future<void> widgetBackgroundMain() => runWidgetBackground();
