import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'intent_router.dart';

/// Dart side of the Android intent handoff. The channel carries only action,
/// opaque URI metadata, MIME, permission and size; it never carries cookies,
/// credentials or file contents.
abstract final class AndroidIntentMethods {
  static const channel = 'pixivfunc/android_intents';
  static const events = 'pixivfunc/android_intents/events';
  static const getInitialIntent = 'getInitialIntent';

  /// Outbound open-url (U6): captions may link outside Pixiv; the app opens
  /// the system browser via an ACTION_VIEW intent. Only http(s) survives the
  /// native gate.
  static const openUrl = 'openUrl';
}

/// Opens an external URL in the system browser. Kept separate from the
/// inbound [AndroidIntentSource] so outbound capability stays explicit.
abstract interface class OutboundUrlOpener {
  /// Returns normally on success; throws when the URL is not http(s) or no
  /// activity can handle it.
  Future<void> openExternal(String url);
}

class MethodChannelOutboundUrlOpener implements OutboundUrlOpener {
  const MethodChannelOutboundUrlOpener([
    this._methodChannel = const MethodChannel(AndroidIntentMethods.channel),
  ]);

  final MethodChannel _methodChannel;

  @override
  Future<void> openExternal(String url) async {
    final ok = await _methodChannel.invokeMethod<bool>(
      AndroidIntentMethods.openUrl,
      {'url': url},
    );
    if (ok != true) {
      throw StateError('openUrl was not confirmed by the platform');
    }
  }
}

/// App-scoped outbound URL capability (U6). Overridable in tests.
final outboundUrlOpenerProvider = Provider<OutboundUrlOpener>((ref) {
  return const MethodChannelOutboundUrlOpener();
});

abstract interface class AndroidIntentSource {
  Future<AndroidIntentResult> readInitial();

  Stream<AndroidIntentResult> get onNewIntent;
}

class MethodChannelAndroidIntentSource implements AndroidIntentSource {
  const MethodChannelAndroidIntentSource([
    this._methodChannel = const MethodChannel(AndroidIntentMethods.channel),
    this._eventChannel = const EventChannel(AndroidIntentMethods.events),
  ]);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  @override
  Future<AndroidIntentResult> readInitial() async {
    final message = await _methodChannel.invokeMethod<Object?>(
      AndroidIntentMethods.getInitialIntent,
    );
    return IntentRouter.routePlatformMessage(message);
  }

  @override
  Stream<AndroidIntentResult> get onNewIntent => _eventChannel
      .receiveBroadcastStream()
      .map(IntentRouter.routePlatformMessage);
}
