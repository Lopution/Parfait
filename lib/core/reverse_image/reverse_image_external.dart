import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

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

/// Desktop launcher: the host browser via `url_launcher`.
class UrlLauncherReverseImageExternalLauncher
    implements ReverseImageExternalLauncher {
  const UrlLauncherReverseImageExternalLauncher();

  @override
  Future<void> open(Uri uri) async {
    validateExternalResultUrl(uri);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      throw PlatformException(
        code: 'external_unavailable',
        message: 'external browser did not accept the URL',
      );
    }
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
