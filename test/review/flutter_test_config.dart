import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'review_device.dart';

/// Loads real fonts for the review harness only; other tests keep
/// FlutterTest's 1em squares.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadReviewFonts();
  await testMain();
}

/// Noto Sans SC is registered as `Roboto`, the family every Material text
/// style names on Android. The test engine has no per-glyph fallback
/// between font files, so Roboto plus a CJK fallback leaves any style that
/// does not carry the fallback list — an app bar title, a chip label — in
/// tofu. One family with both scripts renders every style, like the OEM
/// system font on the user's ROM.
Future<void> loadReviewFonts() async {
  final dir = Directory('$reviewOutDir/fonts');
  const files = [
    'NotoSansSC-Regular.otf',
    'NotoSansSC-Medium.otf',
    'NotoSansSC-Bold.otf',
    'MaterialIcons-Regular.otf',
  ];
  final missing = [
    for (final name in files)
      if (!File('${dir.path}/$name').existsSync()) name,
  ];
  if (missing.isNotEmpty) {
    throw StateError(
      'Missing review fonts $missing in ${dir.path}: run tool/review.sh, or '
      '`python3 tool/fetch_review_fonts.py ${dir.path}`. The test font '
      'would render every shot as boxes.',
    );
  }
  Future<ByteData> bytes(String name) async =>
      ByteData.sublistView(File('${dir.path}/$name').readAsBytesSync());
  final loaders = [
    for (final family in const ['Roboto', 'Noto Sans SC'])
      FontLoader(family)
        ..addFont(bytes('NotoSansSC-Regular.otf'))
        ..addFont(bytes('NotoSansSC-Medium.otf'))
        ..addFont(bytes('NotoSansSC-Bold.otf')),
    FontLoader('MaterialIcons')..addFont(bytes('MaterialIcons-Regular.otf')),
    // The app's own icon font, bundled in the repo.
    FontLoader('iconFont')..addFont(
      Future.value(
        ByteData.sublistView(File('assets/icon.ttf').readAsBytesSync()),
      ),
    ),
  ];
  await Future.wait([for (final loader in loaders) loader.load()]);
}
