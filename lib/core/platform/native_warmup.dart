import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../profile/web_profile_session.dart';

/// One native first-use cost to pay ahead of time.
typedef WarmupStep = Future<void> Function();

/// Steps whose first call blocks the Android main thread — which is also the
/// UI thread — for tens of milliseconds, and otherwise land inside the first
/// artwork detail push:
/// - `flutter/processtext`: every SelectableText/EditableText mount queries
///   the PROCESS_TEXT activities; the engine resolves them and loads their
///   labels on the first call (~50 ms on device, ~0.2 ms afterwards).
/// - `parfait/webprofile` readSession: the first CookieManager access loads
///   the WebView provider (~67 ms). The detail page reads the cookie to fetch
///   multi-page dimensions.
List<WarmupStep> androidChannelWarmupSteps() => [
  () => DefaultProcessTextService().queryTextActions(),
  () => const MethodChannelWebProfileSession().readSessionCookie(),
];

/// Runs [steps] one by one, each only after the app has drawn no frame for
/// [quietFor], so their main-thread stall falls on a still screen instead of
/// a scroll or a route transition.
///
/// The pause is short on purpose. Launch holds the screen still for about a
/// second while the first feed loads, and both steps fit in it. On a device
/// trace a one-second threshold never fired: the user kept the screen moving
/// from launch on, and both stalls landed mid-use, in a page push.
Future<void> warmUpWhenQuiet(
  List<WarmupStep> steps, {
  SchedulerBinding? binding,
  Duration quietFor = const Duration(milliseconds: 300),
  Duration poll = const Duration(milliseconds: 100),
}) async {
  final scheduler = binding ?? SchedulerBinding.instance;
  for (final step in steps) {
    await _untilQuiet(scheduler, quietFor, poll);
    await step();
  }
}

Future<void> _untilQuiet(
  SchedulerBinding binding,
  Duration quietFor,
  Duration poll,
) async {
  var lastFrame = binding.currentSystemFrameTimeStamp;
  var quiet = Duration.zero;
  while (quiet < quietFor) {
    await Future<void>.delayed(poll);
    final frame = binding.currentSystemFrameTimeStamp;
    if (binding.hasScheduledFrame || frame != lastFrame) {
      lastFrame = frame;
      quiet = Duration.zero;
    } else {
      quiet += poll;
    }
  }
}
