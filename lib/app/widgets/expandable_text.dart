import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../motion/spring_size.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';

/// Long text collapsed to [maxLines]. Text that fits shows no toggle. The
/// expanded state is not persisted.
///
/// Collapsed, "Show more" sits at the end of the last line over a fade of
/// the text under it, and a tap anywhere on the text expands it. Links
/// still open: their recognizers enter the gesture arena before the
/// block's, so they win. Expanded, "Show less" sits under the text.
///
/// The fade needs no background colour, so it works on any surface: the
/// text is painted twice, clipped once to all lines but the last and once
/// to the last line alone, and only the second is masked. Nothing is cut
/// out of the text itself, which would be fragile for rich text in every
/// language.
class ExpandableText extends StatefulWidget {
  const ExpandableText(this.text, {super.key, this.maxLines = 4, this.style});

  final InlineSpan text;
  final int maxLines;
  final TextStyle? style;

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

/// Where the collapsed text's last line starts, its baseline, and the
/// collapsed height.
typedef _Fold = ({double lastLineTop, double baseline, double height});

class _ExpandableTextState extends State<ExpandableText> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  /// The style [Text.rich] paints [widget.text] with.
  TextStyle _textStyle(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    return MediaQuery.boldTextOf(context)
        ? style.merge(const TextStyle(fontWeight: FontWeight.bold))
        : style;
  }

  /// The collapsed layout of [widget.text] at [maxWidth], measured with
  /// the [style], scaling and line rules [Text.rich] paints with; null
  /// when the text fits in [ExpandableText.maxLines].
  _Fold? _fold(BuildContext context, TextStyle style, double maxWidth) {
    final defaults = DefaultTextStyle.of(context);
    final painter = TextPainter(
      text: TextSpan(style: style, children: [widget.text]),
      maxLines: widget.maxLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      textWidthBasis: defaults.textWidthBasis,
      textHeightBehavior: defaults.textHeightBehavior,
    )..layout(maxWidth: maxWidth);
    try {
      if (!painter.didExceedMaxLines) return null;
      final last = painter.computeLineMetrics().last;
      return (
        lastLineTop: last.baseline - last.ascent,
        baseline: last.baseline,
        height: painter.height,
      );
    } finally {
      painter.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = _textStyle(context);
        final fold = _fold(context, style, constraints.maxWidth);
        if (fold == null) return Text.rich(widget.text, style: widget.style);
        return SpringSize(
          child: _expanded
              ? _expandedText(context)
              : _collapsedText(context, style, fold, constraints.maxWidth),
        );
      },
    );
  }

  Widget _expandedText(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text.rich(widget.text, style: widget.style),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        // One node: the button announces its expanded state.
        child: MergeSemantics(
          child: Semantics(
            expanded: true,
            child: TextButton(
              // The label ends where the lines above end; the target
              // reaches inward instead.
              style: TextButton.styleFrom(
                padding: const EdgeInsetsDirectional.only(
                  start: FuncSpacing.md,
                ),
                minimumSize: const Size(kMinInteractiveDimension, 40),
                alignment: AlignmentDirectional.centerEnd,
              ),
              onPressed: _toggle,
              child: Text(context.l10n.collapseText),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _collapsedText(
    BuildContext context,
    TextStyle textStyle,
    _Fold fold,
    double width,
  ) {
    final label = context.l10n.expandText;
    // The end of the text, in its size and the accent, on its last
    // baseline. Links are underlined; this is not.
    final labelStyle = textStyle.copyWith(
      color: Theme.of(context).colorScheme.primary,
    );
    final labelPainter = TextPainter(
      text: TextSpan(text: label, style: labelStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout();
    final labelWidth = labelPainter.width;
    final labelAscent = labelPainter.computeLineMetrics().first.ascent;
    labelPainter.dispose();

    Widget lines() =>
        Text.rich(widget.text, style: widget.style, maxLines: widget.maxLines);
    final textDirection = Directionality.of(context);
    return Semantics(
      container: true,
      expanded: false,
      onTapHint: label,
      child: InkWell(
        onTap: _toggle,
        child: Stack(
          // The label keeps its own line height, which may outreach a
          // smaller last line's.
          clipBehavior: Clip.none,
          children: [
            ClipRect(clipper: _Band(0, fold.lastLineTop), child: lines()),
            ExcludeSemantics(
              child: ClipRect(
                clipper: _Band(fold.lastLineTop, fold.height),
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) => _fade(
                    bounds,
                    clearFrom: width - labelWidth - _labelGap,
                    textDirection: textDirection,
                  ),
                  child: lines(),
                ),
              ),
            ),
            PositionedDirectional(
              top: fold.baseline - labelAscent,
              end: 0,
              child: ExcludeSemantics(child: Text(label, style: labelStyle)),
            ),
          ],
        ),
      ),
    );
  }

  /// The clear space between the faded text and "Show more".
  static const _labelGap = FuncSpacing.sm;

  /// How far the last line fades out before it clears.
  static const _fadeWidth = FuncSpacing.xxxl;

  /// A mask, opaque along the line, fading over [_fadeWidth] to clear at
  /// [clearFrom] (from the line's start) and clear to its end.
  static Shader _fade(
    Rect bounds, {
    required double clearFrom,
    required TextDirection textDirection,
  }) {
    final clear = (clearFrom / bounds.width).clamp(0.0, 1.0);
    final fadeStart = ((clearFrom - _fadeWidth) / bounds.width).clamp(
      0.0,
      clear,
    );
    return LinearGradient(
      begin: AlignmentDirectional.centerStart,
      end: AlignmentDirectional.centerEnd,
      // dstIn keeps the text where the mask is opaque; only alpha counts.
      colors: const [
        FuncTokens.white,
        FuncTokens.white,
        FuncTokens.transparent,
        FuncTokens.transparent,
      ],
      stops: [0, fadeStart, clear, 1],
    ).createShader(bounds, textDirection: textDirection);
  }
}

/// The horizontal band from [top] to [bottom] of the box.
class _Band extends CustomClipper<Rect> {
  const _Band(this.top, this.bottom);

  final double top;
  final double bottom;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, top, size.width, bottom);

  @override
  bool shouldReclip(_Band oldClipper) =>
      oldClipper.top != top || oldClipper.bottom != bottom;
}
