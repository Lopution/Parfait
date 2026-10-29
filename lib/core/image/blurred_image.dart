import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// How many times smaller than its decode a blurred image is kept. A blur
/// this wide leaves no detail the full size would show, and the small image
/// costs a sixteenth of the memory and of the blur.
const kBlurDownscale = 4;

/// [imageProvider]'s image blurred once, as its own cache entry.
///
/// `ImageFiltered` blurs its child offscreen on every frame it paints, and
/// Impeller keeps no raster cache: a blurred cover in a scrolling feed was
/// blurred again on every frame. This blurs the decoded image once, shrunk
/// by [kBlurDownscale], into a small image the cache keeps under its own
/// key, so scrolling back paints it like any other image. Shaft's muted
/// cards do the same with a Glide transformation (shrink, then blur).
///
/// The source resolves through the image cache: the sharp image is there
/// when the cover is revealed.
@immutable
class BlurredImage extends ImageProvider<BlurredImageKey> {
  const BlurredImage(this.imageProvider, {required this.sigmaPerWidth});

  final ImageProvider imageProvider;

  /// The blur's standard deviation as a share of the image's width, so a
  /// source decoded narrower than asked for is blurred alike on screen.
  final double sigmaPerWidth;

  // As ResizeImage does: a synchronous source key stays synchronous, which
  // lets a cached image paint in the frame that asks for it.
  @override
  Future<BlurredImageKey> obtainKey(ImageConfiguration configuration) {
    Completer<BlurredImageKey>? completer;
    SynchronousFuture<BlurredImageKey>? result;
    // The sources here (the worker provider and the resizes over it) key
    // synchronously and never fail.
    unawaited(
      imageProvider.obtainKey(configuration).then((Object key) {
        final blurred = BlurredImageKey._(key, sigmaPerWidth);
        if (completer == null) {
          result = SynchronousFuture(blurred);
        } else {
          completer.complete(blurred);
        }
      }),
    );
    if (result case final result?) return result;
    completer = Completer<BlurredImageKey>();
    return completer.future;
  }

  @override
  ImageStreamCompleter loadImage(
    BlurredImageKey key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      _load(),
      informationCollector: () => [
        DiagnosticsProperty<ImageProvider>('Image provider', this),
      ],
    );
  }

  Future<ImageInfo> _load() async {
    final source = await _firstFrame();
    try {
      return ImageInfo(image: await _blur(source.image), scale: source.scale);
    } finally {
      source.dispose();
    }
  }

  /// The source's first frame, resolved through the image cache.
  Future<ImageInfo> _firstFrame() {
    final completer = Completer<ImageInfo>();
    final stream = imageProvider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        completer.complete(info);
      },
      onError: (error, stack) {
        stream.removeListener(listener);
        completer.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  Future<ui.Image> _blur(ui.Image source) async {
    final width = math.max(1, (source.width / kBlurDownscale).round());
    final height = math.max(1, (source.height / kBlurDownscale).round());
    final sigma = sigmaPerWidth * width;
    final recorder = ui.PictureRecorder();
    // Clamped at the edges: sampling past them as transparent would leave a
    // see-through rim on an opaque cover.
    ui.Canvas(recorder).drawImageRect(
      source,
      Offset.zero & Size(source.width.toDouble(), source.height.toDouble()),
      Offset.zero & Size(width.toDouble(), height.toDouble()),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.clamp,
        ),
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is BlurredImage &&
      other.imageProvider == imageProvider &&
      other.sigmaPerWidth == sigmaPerWidth;

  @override
  int get hashCode => Object.hash(imageProvider, sigmaPerWidth);

  @override
  String toString() => 'BlurredImage($imageProvider, $sigmaPerWidth)';
}

/// The cache key of a [BlurredImage]: its source's key and the blur.
@immutable
class BlurredImageKey {
  const BlurredImageKey._(this._sourceKey, this._sigmaPerWidth);

  final Object _sourceKey;
  final double _sigmaPerWidth;

  @override
  bool operator ==(Object other) =>
      other is BlurredImageKey &&
      other._sourceKey == _sourceKey &&
      other._sigmaPerWidth == _sigmaPerWidth;

  @override
  int get hashCode => Object.hash(_sourceKey, _sigmaPerWidth);
}
