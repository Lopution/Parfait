import 'package:flutter/services.dart';

abstract interface class ReverseImageExternalLauncher {
  Future<void> open(Uri uri);
}

class MethodChannelReverseImageExternalLauncher
    implements ReverseImageExternalLauncher {
  MethodChannelReverseImageExternalLauncher([
    this._channel = const MethodChannel('pixivfunc/reverse_image_input'),
  ]);

  final MethodChannel _channel;

  @override
  Future<void> open(Uri uri) async {
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.fragment.isNotEmpty) {
      throw const FormatException('external result URL is not allowed');
    }
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
