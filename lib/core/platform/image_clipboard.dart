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

  /// Writes an encoded image file at [path] (PNG/JPEG/WebP/GIF) onto the OS
  /// clipboard without passing raw image buffers over the method channel.
  /// Returns `false` if the platform rejected the file or lacks support.
  static Future<bool> copyImageFile(
    String path, {
    MethodChannel? channel,
  }) async {
    if (!isDesktopImageClipboardSupported || path.isEmpty) {
      return false;
    }
    try {
      final copied = await (channel ?? _channel).invokeMethod<bool>(
        'copyImageFile',
        <String, Object>{'path': path},
      );
      return copied ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Reads an image from the OS clipboard directly into [targetPath] as PNG
  /// on desktop platforms. Returns `false` when the clipboard has no image or
  /// on unsupported targets.
  static Future<bool> readImageToTempFile(
    String targetPath, {
    MethodChannel? channel,
  }) async {
    if (!isDesktopImageClipboardSupported || targetPath.isEmpty) {
      return false;
    }
    try {
      final wrote = await (channel ?? _channel).invokeMethod<bool>(
        'readImageToTempFile',
        <String, Object>{'targetPath': targetPath},
      );
      return wrote ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// Injectable desktop clipboard image file reader so widget tests can stage
/// pasted images without a live OS clipboard.
final desktopImageClipboardReaderProvider =
    Provider<Future<bool> Function(String targetPath)>(
      (ref) => ImageClipboard.readImageToTempFile,
    );
