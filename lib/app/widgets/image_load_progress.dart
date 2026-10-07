import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../motion/motion_tokens.dart';
import '../theme/func_tokens.dart';

/// Download state of one image, published through `PixivImage.progress`.
@immutable
class ImageLoadProgress {
  /// Not loading: finished, failed, or served from cache.
  const ImageLoadProgress.idle() : loading = false, fraction = null;

  /// [fraction] is null while the total size is unknown.
  const ImageLoadProgress.loading([this.fraction]) : loading = true;

  /// [received] of [total] bytes; an unknown or empty [total] is an
  /// unknown fraction.
  factory ImageLoadProgress.ofBytes(int received, int? total) =>
      ImageLoadProgress.loading(
        total == null || total <= 0 ? null : (received / total).clamp(0.0, 1.0),
      );

  final bool loading;
  final double? fraction;

  @override
  bool operator ==(Object other) =>
      other is ImageLoadProgress &&
      other.loading == loading &&
      other.fraction == fraction;

  @override
  int get hashCode => Object.hash(loading, fraction);

  @override
  String toString() => loading ? 'loading($fraction)' : 'idle';
}

/// Centered progress ring over a loading image. Shows only once a load has
/// lasted [showDelay], so cache hits and fast networks never flash it. It
/// never takes pointer events: taps, pans and zoom reach the image below.
class ImageLoadProgressOverlay extends StatefulWidget {
  const ImageLoadProgressOverlay({super.key, required this.progress});

  final ValueListenable<ImageLoadProgress> progress;

  static const showDelay = Duration(milliseconds: 300);
  static const _discSize = 40.0;
  static const _discPadding = 8.0;
  static const _strokeWidth = 3.0;

  @override
  State<ImageLoadProgressOverlay> createState() =>
      _ImageLoadProgressOverlayState();
}

class _ImageLoadProgressOverlayState extends State<ImageLoadProgressOverlay> {
  Timer? _showTimer;
  var _visible = false;

  @override
  void initState() {
    super.initState();
    widget.progress.addListener(_onProgress);
    _onProgress();
  }

  @override
  void didUpdateWidget(covariant ImageLoadProgressOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.progress, widget.progress)) return;
    oldWidget.progress.removeListener(_onProgress);
    widget.progress.addListener(_onProgress);
    _onProgress();
  }

  @override
  void dispose() {
    widget.progress.removeListener(_onProgress);
    _showTimer?.cancel();
    super.dispose();
  }

  void _onProgress() {
    if (widget.progress.value.loading) {
      if (_visible) return;
      _showTimer ??= Timer(ImageLoadProgressOverlay.showDelay, () {
        _showTimer = null;
        if (mounted) setState(() => _visible = true);
      });
      return;
    }
    _showTimer?.cancel();
    _showTimer = null;
    if (_visible && mounted) setState(() => _visible = false);
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: MotionTokens.resolve(context, MotionTokens.fast),
        child: _visible
            ? Center(
                child: ValueListenableBuilder(
                  valueListenable: widget.progress,
                  builder: (context, progress, _) =>
                      _ProgressDisc(fraction: progress.fraction),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

class _ProgressDisc extends StatelessWidget {
  const _ProgressDisc({required this.fraction});

  final double? fraction;

  @override
  Widget build(BuildContext context) {
    final fraction = this.fraction;
    return SizedBox.square(
      dimension: ImageLoadProgressOverlay._discSize,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: FuncTokens.imageControl,
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: const EdgeInsets.all(ImageLoadProgressOverlay._discPadding),
          child: CircularProgressIndicator(
            value: fraction,
            strokeWidth: ImageLoadProgressOverlay._strokeWidth,
            color: FuncTokens.onImageControl,
            semanticsLabel: context.l10n.imageLoading,
            // Tens, not single percents: each new value is a semantics
            // update, and on Android each update makes an accessibility
            // service re-read the whole tree on the UI thread.
            semanticsValue: fraction == null
                ? null
                : '${(fraction * 10).floor() * 10}%',
          ),
        ),
      ),
    );
  }
}
