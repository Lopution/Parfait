import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/image/jpeg_edge_safe_resize_image.dart';

import 'helpers/image_network.dart';

/// A white JPEG 62 pixels wide whose last block pads its right edge with
/// black, the way pixiv pads with zeros: encoded 64 wide, then declared 62.
Uint8List _paddedJpeg() {
  final image = img.Image(width: 64, height: 8);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  for (final x in [62, 63]) {
    for (var y = 0; y < 8; y++) {
      image.setPixelRgb(x, y, 0, 0, 0);
    }
  }
  final bytes = img.encodeJpg(image, quality: 100);
  for (var i = 0; i + 8 < bytes.length; i++) {
    if (bytes[i] == 0xFF && bytes[i + 1] == 0xC0) {
      bytes[i + 8] = 62; // The frame width's low byte.
      return bytes;
    }
  }
  throw StateError('no baseline frame header');
}

/// The darkest channel of the image's right-hand column.
Future<int> _rightEdgeMin(ui.Image image) async {
  final data = (await image.toByteData())!;
  return [
    for (var y = 0; y < image.height; y++)
      for (var c = 0; c < 3; c++)
        data.getUint8((y * image.width + image.width - 1) * 4 + c),
  ].reduce(math.min);
}

void main() {
  testWidgets('a shrunk JPEG keeps the padding past its edge out', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final bytes = _paddedJpeg();
      // 54 of 62 shrinks by 7/8, 23 by 3/8: the last pixel of either
      // spans the padding.
      for (final width in [54, 23]) {
        final plain = await firstFrame(
          ResizeImage(MemoryImage(Uint8List.fromList(bytes)), width: width),
        );
        expect(await _rightEdgeMin(plain), lessThan(200), reason: 'fixture');
        final safe = await firstFrame(
          JpegEdgeSafeResizeImage(
            MemoryImage(Uint8List.fromList(bytes)),
            width: width,
          ),
        );
        expect(safe.width, greaterThanOrEqualTo(width));
        expect(await _rightEdgeMin(safe), greaterThan(240), reason: '$width');
      }
      // The history cover of a 382-wide file: no clean width below it.
      expect(jpegEdgeSafeDecodeWidth(352, 382), 382);
      expect(jpegEdgeSafeDecodeWidth(180, 382), 191);
    });
  });
}
