import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/icons/ui_icons.dart';
import '../../app/theme/func_semantic_tokens.dart';
import 'novel_layout.dart';

const double _footerBottomOffset = FuncSpacing.xs;
const double _cueIconSize = 16;

/// Bottom padding that keeps the last body line clear of the passive footer
/// strip (progress readout and, under pointer modality, the toolbar cue pill).
double novelReaderFooterReserve(
  BuildContext context, {
  required TextStyle? hintStyle,
  required EdgeInsets stableInsets,
  required bool isPointer,
}) {
  final textScaler = MediaQuery.textScalerOf(context);
  final textDirection = Directionality.of(context);
  final hintPainter = TextPainter(
    text: TextSpan(text: '0', style: hintStyle),
    textScaler: textScaler,
    textDirection: textDirection,
    maxLines: 1,
  )..layout();
  var bandHeight = hintPainter.height;
  hintPainter.dispose();

  if (isPointer) {
    final cuePainter = TextPainter(
      text: TextSpan(text: '0', style: Theme.of(context).textTheme.labelMedium),
      textScaler: textScaler,
      textDirection: textDirection,
      maxLines: 1,
    )..layout();
    final cueHeight =
        math.max(_cueIconSize, cuePainter.height) + FuncSpacing.xxs * 2;
    cuePainter.dispose();
    bandHeight = math.max(bandHeight, cueHeight);
  }

  final hintBand =
      _footerBottomOffset + bandHeight + (isPointer ? FuncSpacing.xs : 0.0);
  return stableInsets.bottom +
      math.max(0.0, hintBand - const NovelLayoutStyle().verticalPadding);
}

/// Computes a whole-line bottom clip boundary for scroll mode's opening
/// viewport so a partial text line never peeks behind the bottom edge fade.
double? initialNovelCleanBottom(
  NovelScrollColumn column, {
  required double viewportHeight,
  required double topPadding,
  required double bottomSafe,
}) {
  final maxBottom = viewportHeight - bottomSafe;
  if (maxBottom <= topPadding) return null;
  double? lastFullBottom;
  var hasPartialLine = false;
  for (var i = 0; i < column.items.length; i++) {
    final itemTop = topPadding + column.offsetOf(i);
    if (itemTop >= maxBottom) break;
    final line = column.items[i].line;
    if (line == null || (line.text.isEmpty && line.image == null)) {
      continue;
    }
    final lineBottom = itemTop + line.height;
    if (lineBottom <= maxBottom) {
      lastFullBottom = lineBottom;
    } else {
      if (line.image == null) hasPartialLine = true;
      break;
    }
  }
  if (!hasPartialLine || lastFullBottom == null) return null;
  if (lastFullBottom < viewportHeight * 0.5) return null;
  return lastFullBottom;
}

/// Passive progress hint and pointer toolbar cue anchored in the reserved
/// bottom strip while the reader chrome is dismissed (NOVEL-05, NOVEL-10).
///
/// Touch keeps the progress hint strictly passive (`IgnorePointer`) and
/// centered on the article column / spread spine. Under pointer modality the
/// interactive toolbar cue sits at the trailing end of the same reserved strip
/// so it never occludes body text on narrow, medium, or two-page layouts.
class NovelReaderFooterStrip extends StatelessWidget {
  const NovelReaderFooterStrip({
    super.key,
    required this.title,
    required this.suffix,
    required this.hintStyle,
    required this.fontSize,
    required this.stableInsets,
    required this.bookLeft,
    required this.isSpread,
    required this.isPointer,
    required this.cueForeground,
    required this.cueBackground,
    required this.showToolbarLabel,
    required this.onShowChrome,
  });

  final String title;
  final String suffix;
  final TextStyle? hintStyle;
  final double fontSize;
  final EdgeInsets stableInsets;
  final double? bookLeft;
  final bool isSpread;
  final bool isPointer;
  final Color cueForeground;
  final Color cueBackground;
  final String showToolbarLabel;
  final VoidCallback onShowChrome;

  @override
  Widget build(BuildContext context) {
    final endInset = bookLeft != null ? FuncSpacing.sm : stableInsets.right;
    return Positioned(
      left: 0,
      right: bookLeft == null ? 0 : null,
      width: bookLeft,
      bottom: _footerBottomOffset + stableInsets.bottom,
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: stableInsets.left,
          end: endInset,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final style = NovelLayoutStyle(fontSize: fontSize);
            final textScaler = MediaQuery.textScalerOf(context);
            final width = isSpread && bookLeft != null
                ? style.spreadContentWidth(
                    availableWidth: constraints.maxWidth,
                    textScaler: textScaler,
                  )
                : style.contentWidth(
                    availableWidth: constraints.maxWidth,
                    textScaler: textScaler,
                  );
            final centerOnSpine = isSpread && bookLeft == null;
            final hint = IgnorePointer(
              child: MergeSemantics(
                child: Row(
                  mainAxisSize: isPointer ? MainAxisSize.min : MainAxisSize.max,
                  mainAxisAlignment: centerOnSpine
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: hintStyle,
                      ),
                    ),
                    Text(suffix, maxLines: 1, style: hintStyle),
                  ],
                ),
              ),
            );
            if (!isPointer) {
              return Center(
                child: SizedBox(
                  width: width,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: style.horizontalPadding,
                    ),
                    child: hint,
                  ),
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: centerOnSpine
                          ? Alignment.center
                          : AlignmentDirectional.centerStart,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: width),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: style.horizontalPadding,
                          ),
                          child: hint,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: FuncSpacing.sm),
                  Material(
                    color: cueBackground,
                    shape: const StadiumBorder(),
                    child: InkWell(
                      key: const ValueKey('novel-pointer-cue'),
                      customBorder: const StadiumBorder(),
                      onTap: onShowChrome,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FuncSpacing.sm,
                          vertical: FuncSpacing.xxs,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              UiIcons.more,
                              size: _cueIconSize,
                              color: cueForeground,
                            ),
                            const SizedBox(width: FuncSpacing.xs),
                            Text(
                              showToolbarLabel,
                              maxLines: 1,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(color: cueForeground),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
