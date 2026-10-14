import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/features/profile/banner_sample.dart';

const _white = [255, 255, 255, 255];
const _black = [0, 0, 0, 255];
const _clear = [0, 0, 0, 0];

/// A [width]×[height] sample whose pixel (x, y) is [pixel]'s RGBA.
BannerSample _sample(
  int width,
  int height,
  List<int> Function(int x, int y) pixel,
) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      rgba.setAll((y * width + x) * 4, pixel(x, y));
    }
  }
  return BannerSample(rgba: rgba, width: width, height: height);
}

void main() {
  // A 400×160 banner; the status bar covers 24 rows of it.
  const box = Size(400, 160);

  test('the status bar takes the brightness of the cover rows under it', () {
    // 40×16 sample: scale 10, so banner row r is sample row r / 10.
    final lightTop = _sample(40, 16, (_, y) => y < 4 ? _white : _black);
    // Wide sample (80×16): cover crops 20 columns off each side.
    final lightEdges = _sample(
      80,
      16,
      (x, _) => x < 20 || x >= 60 ? _white : _black,
    );
    final transparent = _sample(40, 16, (_, _) => _clear);
    const page = Color(0xFFFFFBFE);

    final cases = <(String, BannerSample, double, Color, Brightness)>[
      ('light band at the top', lightTop, 0, page, Brightness.light),
      ('scrolled onto the dark part', lightTop, 40, page, Brightness.dark),
      ('light columns cropped off', lightEdges, 0, page, Brightness.dark),
      ('transparent over a light page', transparent, 0, page, Brightness.light),
      (
        'transparent over a dark page',
        transparent,
        0,
        const Color(0xFF141218),
        Brightness.dark,
      ),
    ];
    for (final (name, sample, offset, underlay, expected) in cases) {
      expect(
        sample.brightnessUnder(
          box: box,
          top: offset,
          bottom: offset + 24,
          underlay: underlay,
        ),
        expected,
        reason: name,
      );
    }
  });
}
