import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/layout_fonts.dart';
import '../helpers/leak_tracking.dart';
import '../helpers/test_preferences.dart';

/// Real glyph widths for the locale layout matrix only: other tests keep
/// FlutterTest's 1em squares, so their pixel assertions and goldens stay.
/// Each case starts with empty in-memory preferences, as in the root
/// config this one replaces.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  enableLeakTracking();
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadLayoutFonts();
  setUp(installMemoryPreferences);
  await testMain();
}
