import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/ambient_wash.dart';

/// [rgb] (0–1) through the 4×5 [matrix] on 0–255 channels, unclamped.
List<double> _apply(List<double> matrix, List<double> rgb) => [
  for (var k = 0; k < 3; k++)
    (matrix[k * 5] * rgb[0] * 255 +
            matrix[k * 5 + 1] * rgb[1] * 255 +
            matrix[k * 5 + 2] * rgb[2] * 255 +
            matrix[k * 5 + 4]) /
        255,
];

double _luma(List<double> rgb) =>
    0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];

void main() {
  test('ambient light keeps the page lightness and a share of the colour', () {
    for (final (brightness, chroma, lift) in [
      (Brightness.light, 0.4, -0.03),
      (Brightness.dark, 0.6, 0.07),
    ]) {
      final theme = replicaTheme(brightness);
      final matrix = AmbientTone.matrixOf(theme);
      final page = theme.colorScheme.surface;
      final washed = [page.r + lift, page.g + lift, page.b + lift];

      // Neutral art, white to black, sinks into the page.
      for (final grey in [1.0, 0.5, 0.0]) {
        final out = _apply(matrix, [grey, grey, grey]);
        for (var k = 0; k < 3; k++) {
          expect(out[k], closeTo(washed[k], 1e-9), reason: '$brightness');
        }
      }
      // Any colour lands at the page's lightness with its hue kept.
      for (final colour in [
        [0.9, 0.1, 0.2],
        [0.24, 0.55, 0.55],
        [0.1, 0.2, 0.9],
      ]) {
        final out = _apply(matrix, colour);
        expect(_luma(out), closeTo(_luma(washed), 1e-9));
        // Its distance from grey, scaled, over the page's own tint.
        for (final k in [0, 2]) {
          expect(
            out[k] - out[1],
            closeTo(
              chroma * (colour[k] - colour[1]) + washed[k] - washed[1],
              1e-9,
            ),
          );
        }
      }
    }
  });
}
