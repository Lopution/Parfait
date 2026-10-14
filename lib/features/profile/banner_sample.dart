import 'dart:typed_data';
import 'dart:ui';

/// A small decode of the profile cover, read to pick status bar icons that
/// contrast with the part of the cover under the status bar.
///
/// The banner paints the cover with `BoxFit.cover` anchored at the top
/// centre; [brightnessUnder] maps a band of the banner box back to the
/// sample's pixels the same way.
class BannerSample {
  BannerSample({required this.rgba, required this.width, required this.height})
    : assert(rgba.length == width * height * 4);

  /// Decode width of the sample: a status-bar band spans several of its
  /// rows on any phone, and reading it costs nothing per frame.
  static const decodeWidth = 64;

  /// Mean relative luminance at which dark and light icons have equal WCAG
  /// contrast: (L + 0.05) / 0.05 = 1.05 / (L + 0.05).
  static const contrastSplitLuminance = 0.179;

  /// `ImageByteFormat.rawRgba`: row-major RGBA, premultiplied alpha.
  final Uint8List rgba;
  final int width;
  final int height;

  /// The brightness of the cover inside the band [top]..[bottom] of a
  /// banner box of size [box] (logical pixels, banner coordinates).
  /// Transparent pixels show [underlay].
  Brightness brightnessUnder({
    required Size box,
    required double top,
    required double bottom,
    required Color underlay,
  }) {
    final scale = box.width / width > box.height / height
        ? box.width / width
        : box.height / height;
    // Horizontally centred: the columns the box shows.
    final cropX = (width * scale - box.width) / 2 / scale;
    final x0 = cropX.floor().clamp(0, width - 1);
    final x1 = (width - cropX).ceil().clamp(x0 + 1, width);
    final y0 = (top / scale).floor().clamp(0, height - 1);
    final y1 = (bottom / scale).ceil().clamp(y0 + 1, height);

    var sum = 0.0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        sum += _luminanceAt((y * width + x) * 4, underlay);
      }
    }
    final mean = sum / ((x1 - x0) * (y1 - y0));
    return mean > contrastSplitLuminance ? Brightness.light : Brightness.dark;
  }

  double _luminanceAt(int i, Color underlay) {
    final cover = 1 - rgba[i + 3] / 255;
    double channel(int premultiplied, double under) =>
        premultiplied / 255 + cover * under;
    return Color.from(
      alpha: 1,
      red: channel(rgba[i], underlay.r),
      green: channel(rgba[i + 1], underlay.g),
      blue: channel(rgba[i + 2], underlay.b),
    ).computeLuminance();
  }
}
