import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// One shared text scale for a group of compact labels (bottom bar
/// destinations, segments): the widest label decides, so every label in the
/// group renders at the same size. Computed by the host from the slot width
/// it lays out — [FitLabel] itself never measures, so it works inside
/// widgets that query intrinsic sizes (a `LayoutBuilder` cannot).
@immutable
final class LabelFit {
  const LabelFit({required this.scale, required this.truncates});

  /// The labels fit at their natural size.
  static const none = LabelFit(scale: 1, truncates: false);

  /// Below this the text gets hard to read; past it labels ellipsize.
  static const double minScale = 0.8;

  /// Fits the widest of [labels] in [slotWidth]. An unbounded slot (a
  /// horizontally scrolling row) never scales.
  static LabelFit group({
    required Iterable<String> labels,
    required TextStyle style,
    required TextScaler textScaler,
    required TextDirection textDirection,
    required double slotWidth,
  }) {
    if (!slotWidth.isFinite) return none;
    final widest = labels.fold(
      0.0,
      (widest, label) => math.max(
        widest,
        measureLabel(label, style, textScaler, textDirection),
      ),
    );
    if (widest <= slotWidth) return none;
    // Glyph advances at the scaled font size round a hair wider than the
    // linear estimate; the slack keeps the widest label from ellipsizing.
    final room = slotWidth - _scaleSlack;
    final scale = math.max(room / widest, minScale);
    return LabelFit(scale: scale, truncates: widest * minScale > room);
  }

  static const _scaleSlack = 1.0;

  /// The single-line width [FitLabel] draws [label] at before scaling.
  static double measureLabel(
    String label,
    TextStyle style,
    TextScaler textScaler,
    TextDirection textDirection,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.maxIntrinsicWidth;
    painter.dispose();
    return width;
  }

  final double scale;
  final bool truncates;

  /// [base] times [scale]: what [FitLabel] draws with. Measure through it
  /// for the exact painted width.
  TextScaler scaler(TextScaler base) =>
      scale == 1 ? base : _ScaledTextScaler(base, scale);

  @override
  bool operator ==(Object other) =>
      other is LabelFit && other.scale == scale && other.truncates == truncates;

  @override
  int get hashCode => Object.hash(scale, truncates);
}

/// A single-line label drawn at its group's [LabelFit]: the ambient text
/// scaler times [LabelFit.scale] (keeping Android's non-linear font
/// scaling), ellipsized past the floor with a tooltip carrying the full
/// text. Measure with [LabelFit.group] using the style the label is drawn
/// in: [style] merged over the ambient default text style, or the ambient
/// style alone when [style] is null (a button supplying its own).
class FitLabel extends StatelessWidget {
  const FitLabel(
    this.text, {
    super.key,
    required this.fit,
    this.style,
    this.textAlign = TextAlign.center,
  });

  final String text;
  final LabelFit fit;
  final TextStyle? style;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      style: style,
      textAlign: textAlign,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textScaler: fit.scaler(MediaQuery.textScalerOf(context)),
    );
    // Screen readers already read the paragraph's full text.
    return fit.truncates
        ? Tooltip(message: text, excludeFromSemantics: true, child: label)
        : label;
  }
}

@immutable
final class _ScaledTextScaler extends TextScaler {
  const _ScaledTextScaler(this.base, this.factor);

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * factor;

  @override
  bool operator ==(Object other) =>
      other is _ScaledTextScaler &&
      other.base == base &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}
