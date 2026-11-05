import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Android's predictive back swipe, as the engine reports it on the
/// `flutter/backgesture` channel.
Future<void> sendBackGesture(String method, [Map<String, dynamic>? arguments]) {
  final data = const StandardMethodCodec().encodeMethodCall(
    MethodCall(method, arguments),
  );
  return TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('flutter/backgesture', data, (_) {});
}

/// A back swipe starting at the left edge.
Future<void> startBackGesture() => sendBackGesture('startBackGesture', {
  'touchOffset': <double>[5.0, 300.0],
  'progress': 0.0,
  'swipeEdge': 0,
});

/// The back swipe, 100 px in, at [progress].
Future<void> dragBackGesture(double progress) =>
    sendBackGesture('updateBackGestureProgress', {
      'touchOffset': <double>[100.0, 300.0],
      'progress': progress,
      'swipeEdge': 0,
    });

Future<void> commitBackGesture() => sendBackGesture('commitBackGesture');

Future<void> cancelBackGesture() => sendBackGesture('cancelBackGesture');
