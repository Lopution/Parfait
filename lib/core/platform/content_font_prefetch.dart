import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_caps.dart';

const _channel = MethodChannel('parfait/fonts');

/// Asks Android to read the fonts user content is laid out with into the
/// page cache on a background thread, so the card titles of a freshly
/// loaded page do not stall the UI thread on storage reads
/// (`ContentFontPrefetcher.kt`). Android throttles the requests; elsewhere
/// this does nothing.
///
/// Fire-and-forget: a performance hint, so failures are logged, never thrown.
void requestContentFontPrefetch() {
  if (!PlatformCaps.system().isAndroid) return;
  unawaited(
    _channel.invokeMethod<void>('prefetch').catchError((Object error) {
      debugPrint('fonts: prefetch failed: $error');
    }),
  );
}
