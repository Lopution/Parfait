import 'package:flutter/foundation.dart';

/// Single owner of debug console logging (C5d).
///
/// Release builds compile this out entirely: diagnostic prints never leak
/// into release consoles.
void log(String message) {
  if (kReleaseMode) return;
  debugPrint(message);
}
