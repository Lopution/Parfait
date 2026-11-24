import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the current platform supports reading/writing encoded image bytes
/// through [ImageClipboard].
bool get isDesktopImageClipboardSupported {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
  };
}

/// Cross-platform desktop original-image clipboard bridge.
class ImageClipboard {
  const ImageClipboard._();

  static const MethodChannel _channel = MethodChannel(
    'parfait/image_clipboard',
  );

  /// Writes encoded image [bytes] (PNG/JPEG/WebP/GIF) as an image entry on the
  /// OS clipboard. Returns `false` if the platform rejected or lacks support.
  static Future<bool> copyImageBytes(Uint8List bytes) async {
    if (!isDesktopImageClipboardSupported || bytes.isEmpty) {
      return false;
    }
    try {
      final copied = await _channel.invokeMethod<bool>(
        'copyImage',
        <String, Object>{'bytes': bytes},
      );
      return copied ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Reads an encoded image (PNG) from the OS clipboard on desktop platforms.
  /// Returns `null` when the clipboard has no image or on unsupported targets.
  static Future<Uint8List?> readImageBytes({MethodChannel? channel}) async {
    if (!isDesktopImageClipboardSupported) {
      return null;
    }
    try {
      final bytes = await (channel ?? _channel).invokeMethod<Uint8List>(
        'readImage',
      );
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// Injectable desktop clipboard image reader so widget tests can supply
/// pasted image bytes without a live OS clipboard.
final desktopImageClipboardReaderProvider =
    Provider<Future<Uint8List?> Function()>(
      (ref) => ImageClipboard.readImageBytes,
    );
