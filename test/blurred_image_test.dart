import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/image/blurred_image.dart';

/// A [size]-pixel square PNG, black on its left half and white on its right.
Future<Uint8List> _halvesPng(int size) async {
  final recorder = ui.PictureRecorder();
  final half = size / 2;
  Canvas(recorder)
    ..drawRect(
      Rect.fromLTWH(0, 0, half, size.toDouble()),
      Paint()..color = const Color(0xFF000000),
    )
    ..drawRect(
      Rect.fromLTWH(half, 0, half, size.toDouble()),
      Paint()..color = const Color(0xFFFFFFFF),
    );
  final image = await recorder.endRecording().toImage(size, size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

/// The first image [provider] resolves to.
Future<ui.Image> _resolve(ImageProvider provider) {
  final image = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener((info, _) {
    stream.removeListener(listener);
    image.complete(info.image);
  }, onError: image.completeError);
  stream.addListener(listener);
  return image.future;
}

void main() {
  setUp(
    () => imageCache
      ..clear()
      ..clearLiveImages(),
  );

  testWidgets('a blurred image is a quarter of its decode, opaque to the '
      'edges, and cached apart from the sharp one', (tester) async {
    await tester.runAsync(() async {
      final sharp = MemoryImage(await _halvesPng(64));
      final blurred = BlurredImage(sharp, sigmaPerWidth: 0.1);
      final image = await _resolve(blurred);
      expect(
        (image.width, image.height),
        (16, 16),
        reason: 'shrunk $kBlurDownscale×',
      );

      final rgba = (await image.toByteData())!;
      int pixel(int x, int y) => rgba.getUint32((y * 16 + x) * 4);
      for (var y = 0; y < 16; y++) {
        for (var x = 0; x < 16; x++) {
          expect(pixel(x, y) & 0xFF, 0xFF, reason: 'opaque at ($x, $y)');
        }
      }
      // The black and white halves meet in grey; the far edges keep their
      // colours (red channel, the top byte).
      int red(int x) => pixel(x, 8) >> 24;
      expect(red(0), lessThan(0x20));
      expect(red(15), greaterThan(0xE0));
      expect(red(7), inInclusiveRange(0x30, 0xD0));
      expect(red(8), inInclusiveRange(0x30, 0xD0));

      // Scrolling back paints the cached blur; revealing, the sharp image.
      final key = await blurred.obtainKey(ImageConfiguration.empty);
      expect(imageCache.containsKey(key), isTrue);
      expect(
        imageCache.containsKey(await sharp.obtainKey(ImageConfiguration.empty)),
        isTrue,
      );
      final other = BlurredImage(sharp, sigmaPerWidth: 0.2);
      expect(await other.obtainKey(ImageConfiguration.empty), isNot(key));
    });
  });
}
