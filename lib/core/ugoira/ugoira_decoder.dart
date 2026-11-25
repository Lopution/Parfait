import 'dart:typed_data';
import 'dart:ui' as ui;

import '../image/jpeg_edge_safe_resize_image.dart';
import 'ugoira_limits.dart';
import 'ugoira_zip.dart';

/// A frame failed after the archive entry was accepted but before it could be
/// rendered. The original bytes are never included in the exception.
class UgoiraDecodeException implements Exception {
  const UgoiraDecodeException(this.message);

  final String message;

  @override
  String toString() => 'UgoiraDecodeException: $message';
}

/// Decodes exactly one already-indexed frame. Header validation is performed
/// before [ui.instantiateImageCodec] so a forged dimension cannot force native
/// pixel allocation.
class UgoiraFrameDecoder {
  const UgoiraFrameDecoder({this.limits = const UgoiraLimits()});

  final UgoiraLimits limits;

  Future<ui.Image> decode(List<int> bytes, {int? targetWidth}) async {
    final header = UgoiraFrameHeader.parse(bytes);
    header.validate(limits);
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final resolvedTargetWidth = _resolveTargetWidth(data, header, targetWidth);
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      if (resolvedTargetWidth != null) {
        buffer = await ui.ImmutableBuffer.fromUint8List(data);
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        if (descriptor.width != header.width ||
            descriptor.height != header.height) {
          throw const UgoiraDecodeException(
            'decoded frame dimensions differ from header',
          );
        }
        codec = await descriptor.instantiateCodec(
          targetWidth: resolvedTargetWidth,
        );
      } else {
        codec = await ui.instantiateImageCodec(data);
      }
      final frame = await codec.getNextFrame();
      final image = frame.image;
      if (resolvedTargetWidth == null) {
        if (image.width != header.width || image.height != header.height) {
          image.dispose();
          throw const UgoiraDecodeException(
            'decoded frame dimensions differ from header',
          );
        }
      } else if (image.width <= 0 ||
          image.height <= 0 ||
          image.width > header.width ||
          image.height > header.height) {
        image.dispose();
        throw const UgoiraDecodeException(
          'scaled frame dimensions exceed header',
        );
      }
      return image;
    } on UgoiraDecodeException {
      rethrow;
    } catch (error) {
      throw UgoiraDecodeException('frame decode failed: $error');
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static int? _resolveTargetWidth(
    Uint8List data,
    UgoiraFrameHeader header,
    int? targetWidth,
  ) {
    if (targetWidth == null ||
        targetWidth <= 0 ||
        targetWidth >= header.width) {
      return null;
    }
    final isJpeg = data.length >= 2 && data[0] == 0xFF && data[1] == 0xD8;
    final safe = isJpeg
        ? jpegEdgeSafeDecodeWidth(targetWidth, header.width)
        : targetWidth;
    return safe < header.width ? safe : null;
  }
}
