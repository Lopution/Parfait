import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// A [ResizeImage] for JPEG files that never leaves a stray column on the
/// right edge.
///
/// A decoder asked for a smaller JPEG shrinks it inside the DCT: an 8×8
/// block becomes n×n pixels, n/8 picked from the requested width. When the
/// source width times n/8 is fractional, the last output pixel spans the
/// padding the encoder put past the right edge of the last block. pixiv
/// fills that padding with zeros, which decode as a green column. So the
/// decode width is raised to the nearest one the blocks divide into whole
/// pixels — the full width at worst — and painting scales it down to the
/// slot. The bottom padding of pixiv's files replicates the last row and
/// is left alone.
class JpegEdgeSafeResizeImage extends ResizeImage {
  const JpegEdgeSafeResizeImage(super.imageProvider, {required int width})
    : super(width: width);

  @override
  ImageStreamCompleter loadImage(
    ResizeImageKey key,
    ImageDecoderCallback decode,
  ) => super.loadImage(
    key,
    (buffer, {getTargetSize}) => decode(
      buffer,
      getTargetSize: getTargetSize == null
          ? null
          : (intrinsicWidth, intrinsicHeight) {
              final size = getTargetSize(intrinsicWidth, intrinsicHeight);
              final width = size.width;
              if (width == null) return size;
              return ui.TargetImageSize(
                width: jpegEdgeSafeDecodeWidth(width, intrinsicWidth),
              );
            },
    ),
  );

  /// Whether [url] names a JPEG file, the only kind decoded by DCT blocks.
  static bool appliesTo(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return path.endsWith('.jpg') || path.endsWith('.jpeg');
  }
}

/// The smallest width of at least [target] that a JPEG [intrinsic] pixels
/// wide shrinks to in whole pixels: intrinsic × n/8 for some n in 1..8.
int jpegEdgeSafeDecodeWidth(int target, int intrinsic) {
  if (target >= intrinsic) return target;
  for (var n = 1; n < _dctBlock; n++) {
    if (intrinsic * n % _dctBlock != 0) continue;
    final width = intrinsic * n ~/ _dctBlock;
    if (width >= target) return width;
  }
  return intrinsic;
}

/// The JPEG block size, the denominator of every scale a decoder applies.
const _dctBlock = 8;
