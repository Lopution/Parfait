import 'package:flutter/services.dart';

import '../platform/android_intent_channel.dart';

abstract interface class ReverseImageExternalLauncher {
  Future<void> open(Uri uri);
}

/// Same allowlist for every platform: external results are plain https
/// links — no credentials, ports, fragments or non-web schemes.
void validateExternalResultUrl(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.fragment.isNotEmpty) {
    throw const FormatException('external result URL is not allowed');
  }
}

/// Adapts the app-scoped [OutboundUrlOpener] capability: Android routes to
/// the platform channel, desktop to `url_launcher` — selected by
/// `outboundUrlOpenerProvider`, so no platform check lives here.
class OutboundReverseImageExternalLauncher
    implements ReverseImageExternalLauncher {
  const OutboundReverseImageExternalLauncher(this._opener);

  final OutboundUrlOpener _opener;

  @override
  Future<void> open(Uri uri) async {
    validateExternalResultUrl(uri);
    await _opener.openExternal(uri.toString());
  }
}

class MethodChannelReverseImageExternalLauncher
    implements ReverseImageExternalLauncher {
  MethodChannelReverseImageExternalLauncher([
    this._channel = const MethodChannel('pixivfunc/reverse_image_input'),
  ]);

  final MethodChannel _channel;

  @override
  Future<void> open(Uri uri) async {
    validateExternalResultUrl(uri);
    try {
      final opened = await _channel.invokeMethod<Object?>('openExternal', {
        'url': uri.toString(),
      });
      if (opened is! bool || !opened) {
        throw PlatformException(
          code: 'external_unavailable',
          message: 'external browser did not accept the URL',
        );
      }
    } on MissingPluginException {
      throw PlatformException(
        code: 'external_unavailable',
        message: 'external browser is unavailable on this platform',
      );
    }
  }
}
