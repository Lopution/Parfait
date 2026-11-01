import 'package:material_ui/material_ui.dart';

import '../../core/image/blurred_image.dart';
import '../../core/log.dart';
import '../motion/motion_tokens.dart';

/// Ambient light: an image's own colour at the page's lightness (THEME-19).
/// Each pixel's luma becomes the page's (moved by a small lift) and its
/// chroma is scaled, so a dark image does not grey a light page nor a
/// white one fog a dark page, and neutral images sink into the page.
abstract final class AmbientTone {
  /// Where the wash's lightness sits against the page's: a touch below it
  /// on light, above it on dark, so a colour has room to show.
  static const double _lightLift = -0.03;
  static const double _darkLift = 0.07;

  /// How much of the image's colour, its distance from grey, survives.
  /// Saturated colours clip at the gamut edge and lose some of it: a share
  /// that never clips (about 0.04 on light, 0.18 on dark) leaves no colour.
  static const double _lightChroma = 0.4;
  static const double _darkChroma = 0.6;

  static ColorFilter of(ThemeData theme) => ColorFilter.matrix(matrixOf(theme));

  /// The row-major 4×5 matrix [of] applies, on 0–255 channels.
  @visibleForTesting
  static List<double> matrixOf(ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    final page = theme.colorScheme.surface;
    final lift = dark ? _darkLift : _lightLift;
    final chroma = dark ? _darkChroma : _lightChroma;
    const luma = [0.2126, 0.7152, 0.0722];
    final base = [page.r, page.g, page.b];
    return <double>[
      for (var k = 0; k < 3; k++) ...[
        for (var j = 0; j < 3; j++) chroma * ((k == j ? 1 : 0) - luma[j]),
        0,
        (base[k] + lift) * 255,
      ],
      0, 0, 0, 1, 0, //
    ];
  }
}

/// [image] blurred and tone-locked ([AmbientTone]) over the page colour,
/// covering its box. Opaque, so it also hides what scrolls under it. Fades
/// are the caller's.
///
/// It draws in the page's own pass: the blur is done once at decode
/// ([BlurredImage]), and the tone and the fade-in ride on the image's
/// paint. Filter widgets around it drew it offscreen on every frame
/// (Impeller keeps no raster cache): a side swipe over two detail pages
/// drew eight offscreen layers a frame and dropped frames.
class AmbientWash extends StatelessWidget {
  const AmbientWash({
    super.key,
    required this.image,
    this.blur = 28,
    this.alignment = Alignment.center,
  });

  /// A small decode of an image the page already holds.
  final ImageProvider image;

  /// The blur's sigma in logical pixels, taken over the box's width: an
  /// image cropped at its sides to cover the box blurs a little more.
  final double blur;

  /// Where the image sits when it is cropped to cover the box.
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          if (!width.isFinite || width <= 0) return const SizedBox.expand();
          return _WashImage(
            image: BlurredImage(image, sigmaPerWidth: blur / width),
            tone: AmbientTone.of(theme),
            alignment: alignment,
          );
        },
      ),
    );
  }
}

/// The blurred image, fading in when it was not decoded yet.
class _WashImage extends StatefulWidget {
  const _WashImage({
    required this.image,
    required this.tone,
    required this.alignment,
  });

  final ImageProvider image;
  final ColorFilter tone;
  final Alignment alignment;

  @override
  State<_WashImage> createState() => _WashImageState();
}

class _WashImageState extends State<_WashImage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(vsync: this);
  late final ImageStreamListener _listener = ImageStreamListener(
    _onImage,
    onError: _onError,
  );
  ImageStream? _stream;

  /// The last image shown: a new key (a resized box, another theme's
  /// blur) keeps it until its own arrives.
  ImageInfo? _info;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _fade.duration = MotionTokens.resolve(context, MotionTokens.imageFade);
    _resolve();
  }

  @override
  void didUpdateWidget(_WashImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) _resolve();
  }

  void _resolve() {
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    final first = _info == null;
    _info?.dispose();
    setState(() => _info = info);
    if (!first) return;
    // A wash already decoded (scrolling back, the second visit) shows at
    // once, as PixivImage does; a fresh one fades in over the page colour.
    if (synchronousCall ||
        !TickerMode.getValuesNotifier(context).value.enabled) {
      _fade.value = 1;
    } else {
      _fade.forward(from: 0);
    }
  }

  // The page colour stays: the wash only lights the frame. A wash of the
  // previous image would light it with another subject.
  void _onError(Object error, StackTrace? stack) {
    log('AmbientWash: ${widget.image} failed: $error');
    if (_info == null) return;
    _info!.dispose();
    setState(() => _info = null);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null) return const SizedBox.expand();
    // The fade repaints only the wash.
    return RepaintBoundary(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _WashPainter(
            info: info,
            tone: widget.tone,
            alignment: widget.alignment,
            opacity: _fade,
          ),
        ),
      ),
    );
  }
}

class _WashPainter extends CustomPainter {
  _WashPainter({
    required this.info,
    required this.tone,
    required this.alignment,
    required this.opacity,
  }) : super(repaint: opacity);

  final ImageInfo info;
  final ColorFilter tone;
  final Alignment alignment;
  final Animation<double> opacity;

  @override
  void paint(Canvas canvas, Size size) {
    // A colour matrix and an alpha on an image draw are applied as it is
    // sampled; neither needs a layer.
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: info.image,
      scale: info.scale,
      fit: BoxFit.cover,
      alignment: alignment,
      colorFilter: tone,
      opacity: opacity.value,
      filterQuality: FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_WashPainter oldDelegate) =>
      !identical(info, oldDelegate.info) ||
      tone != oldDelegate.tone ||
      alignment != oldDelegate.alignment ||
      opacity != oldDelegate.opacity;
}
