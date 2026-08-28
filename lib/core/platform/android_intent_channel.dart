import 'package:flutter/services.dart';

import 'intent_router.dart';

/// Dart side of the Android intent handoff. The channel carries only action,
/// opaque URI metadata, MIME, permission and size; it never carries cookies,
/// credentials or file contents.
abstract final class AndroidIntentMethods {
  static const channel = 'pixivfunc/android_intents';
  static const events = 'pixivfunc/android_intents/events';
  static const getInitialIntent = 'getInitialIntent';
}

class MethodChannelAndroidIntentSource {
  const MethodChannelAndroidIntentSource([
    this._methodChannel = const MethodChannel(AndroidIntentMethods.channel),
    this._eventChannel = const EventChannel(AndroidIntentMethods.events),
  ]);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  Future<AndroidIntentResult> readInitial() async {
    final message = await _methodChannel.invokeMethod<Object?>(
      AndroidIntentMethods.getInitialIntent,
    );
    return IntentRouter.routePlatformMessage(message);
  }

  Stream<AndroidIntentResult> get onNewIntent => _eventChannel
      .receiveBroadcastStream()
      .map(IntentRouter.routePlatformMessage);
}
