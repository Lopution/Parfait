import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import 'image_input.dart';

/// Shrinks a large picked image before it is uploaded, instead of turning
/// it away: engines match on far smaller thumbnails, and a phone photo of
/// tens of megapixels is over IQDB's limits and slow on mobile data.
abstract final class ReverseImageDownscale {
  /// Long edge of the image that is uploaded.
  static const targetLongEdge = 2048;

  /// Largest file uploaded as picked — IQDB's ceiling, the strictest engine.
  static const maxUploadBytes = 8 * 1024 * 1024;

  static const _jpegQuality = 90;

  /// Whether [info] is shrunk before upload.
  static bool needed(ReverseImageInputInfo info) =>
      math.max(info.width, info.height) > targetLongEdge ||
      info.sizeBytes > maxUploadBytes;

  /// Writes [source] scaled to [targetLongEdge] as a JPEG at [target].
  ///
  /// The engine decodes straight to the target size, so a large photo is
  /// never held at full resolution. Transparency is flattened onto white:
  /// JPEG has no alpha, and engines compare what a viewer sees.
  static Future<void> toJpeg({
    required String source,
    required String target,
  }) async {
    final bytes = await File(source).readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        final scale = targetLongEdge / math.max(width, height);
        if (scale >= 1) return ui.TargetImageSize(width: width, height: height);
        return ui.TargetImageSize(
          width: math.max(1, (width * scale).round()),
          height: math.max(1, (height * scale).round()),
        );
      },
    );
    final ui.Image frame;
    try {
      frame = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    final width = frame.width;
    final height = frame.height;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder)
      ..drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src)
      ..drawImage(frame, ui.Offset.zero, ui.Paint());
    frame.dispose();
    final picture = recorder.endRecording();
    final flat = await picture.toImage(width, height);
    picture.dispose();
    final rgba = await flat.toByteData(format: ui.ImageByteFormat.rawRgba);
    flat.dispose();
    if (rgba == null) {
      throw const ReverseImageInputException(
        ReverseImageInputFailureCode.unreadable,
        'image could not be scaled',
      );
    }
    final pixels = rgba.buffer.asUint8List();
    final jpeg = await Isolate.run(
      () => img.encodeJpg(
        img.Image.fromBytes(
          width: width,
          height: height,
          bytes: pixels.buffer,
          numChannels: 4,
        ),
        quality: _jpegQuality,
      ),
    );
    await File(target).writeAsBytes(jpeg, flush: true);
  }
}
