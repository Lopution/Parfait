import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/layout_fonts.dart';
import '../helpers/leak_tracking.dart';

/// Real glyph widths for the locale layout matrix only: other tests keep
/// FlutterTest's 1em squares, so their pixel assertions and goldens stay.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  enableLeakTracking();
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadLayoutFonts();
  await testMain();
}
