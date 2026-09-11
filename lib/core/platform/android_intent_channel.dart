import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'intent_router.dart';
import 'platform_caps.dart';

/// Dart side of the Android intent handoff. The channel carries only action,
/// opaque URI metadata, MIME, permission and size; it never carries cookies,
/// credentials or file contents.
abstract final class _AndroidIntentMethods {
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
    this._methodChannel = const MethodChannel(_AndroidIntentMethods.channel),
  ]);

  final MethodChannel _methodChannel;

  @override
  Future<void> openExternal(String url) async {
    final ok = await _methodChannel.invokeMethod<bool>(
      _AndroidIntentMethods.openUrl,
      {'url': url},
    );
    if (ok != true) {
      throw StateError('openUrl was not confirmed by the platform');
    }
  }
}

/// App-scoped outbound URL capability (U6). Overridable in tests.
final outboundUrlOpenerProvider = Provider<OutboundUrlOpener>((ref) {
  return ref.watch(platformCapsProvider).isAndroid
      ? const MethodChannelOutboundUrlOpener()
      : const UrlLauncherOutboundUrlOpener();
});

abstract interface class AndroidIntentSource {
  Future<AndroidIntentResult> readInitial();

  Stream<AndroidIntentResult> get onNewIntent;
}

class MethodChannelAndroidIntentSource implements AndroidIntentSource {
  const MethodChannelAndroidIntentSource([
    this._methodChannel = const MethodChannel(_AndroidIntentMethods.channel),
    this._eventChannel = const EventChannel(_AndroidIntentMethods.events),
  ]);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  @override
  Future<AndroidIntentResult> readInitial() async {
    final message = await _methodChannel.invokeMethod<Object?>(
      _AndroidIntentMethods.getInitialIntent,
    );
    return IntentRouter.routePlatformMessage(message);
  }

  @override
  Stream<AndroidIntentResult> get onNewIntent => _eventChannel
      .receiveBroadcastStream()
      .map(IntentRouter.routePlatformMessage);
}

/// Desktop intent source: no ACTION_* delivery exists, so the source is a
/// permanent empty stream — the bridge stays mounted but inert.
class NoopAndroidIntentSource implements AndroidIntentSource {
  const NoopAndroidIntentSource();

  @override
  Future<AndroidIntentResult> readInitial() async =>
      const IgnoredAndroidIntent('unsupported platform');

  @override
  Stream<AndroidIntentResult> get onNewIntent => const Stream.empty();
}

/// Desktop outbound opener via `url_launcher`: the same contract as the
/// channel impl — only http(s) is opened, anything else throws.
class UrlLauncherOutboundUrlOpener implements OutboundUrlOpener {
  const UrlLauncherOutboundUrlOpener();

  @override
  Future<void> openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('http') && !uri.isScheme('https')) {
      throw StateError('openUrl refused a non-http(s) url');
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      throw StateError('openUrl was not confirmed by the platform');
    }
  }
}
