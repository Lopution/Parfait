import 'dart:typed_data';
import 'dart:ui' as ui;

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

  Future<ui.Image> decode(List<int> bytes) async {
    final header = UgoiraFrameHeader.parse(bytes);
    header.validate(limits);
    final codec = await _createCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      if (image.width != header.width || image.height != header.height) {
        image.dispose();
        throw const UgoiraDecodeException(
          'decoded frame dimensions differ from header',
        );
      }
      return image;
    } on UgoiraDecodeException {
      rethrow;
    } catch (error) {
      throw UgoiraDecodeException('frame decode failed: $error');
    } finally {
      codec.dispose();
    }
  }

  Future<ui.Codec> _createCodec(List<int> bytes) async {
    try {
      return await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    } catch (error) {
      throw UgoiraDecodeException('frame codec rejected input: $error');
    }
  }
}
