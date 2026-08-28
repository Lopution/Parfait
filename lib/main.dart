import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/widget/widget_background.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: PixivFuncApp()));
}

/// Headless entrypoint for the Android widget worker.
///
/// The Flutter engine resolves background entrypoints against the root
/// library, so the named function must live here; the implementation stays
/// in `core/widget/widget_background.dart`.
@pragma('vm:entry-point')
Future<void> widgetBackgroundMain() => runWidgetBackground();
