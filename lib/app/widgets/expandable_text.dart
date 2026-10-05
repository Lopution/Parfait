import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../motion/motion_tokens.dart';

/// Long text collapsed to [maxLines] with a Show more / Show less toggle
/// under it. Links inside [text] stay tappable in both states. Text that
/// fits shows no toggle. The expanded state is not persisted.
///
/// The toggle sits under the text rather than inside its last line:
/// truncating rich text precisely for every language is fragile, and a
/// button below reads just as clearly.
class ExpandableText extends StatefulWidget {
  const ExpandableText(this.text, {super.key, this.maxLines = 4, this.style});

  final InlineSpan text;
  final int maxLines;
  final TextStyle? style;

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  bool _expanded = false;

  /// Whether [widget.text] needs more than [ExpandableText.maxLines] lines
  /// at [maxWidth], measured with the same style and scaling [Text.rich]
  /// renders with.
  bool _overflows(BuildContext context, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(
        style: DefaultTextStyle.of(context).style.merge(widget.style),
        children: [widget.text],
      ),
      maxLines: widget.maxLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout(maxWidth: maxWidth);
    final overflows = painter.didExceedMaxLines;
    painter.dispose();
    return overflows;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!_overflows(context, constraints.maxWidth)) {
          return Text.rich(widget.text, style: widget.style);
        }
        final l10n = context.l10n;
        return AnimatedSize(
          duration: MotionTokens.resolve(context, MotionTokens.medium),
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text.rich(
                widget.text,
                style: widget.style,
                maxLines: _expanded ? null : widget.maxLines,
                overflow: _expanded ? null : TextOverflow.ellipsis,
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                // One node: the button announces its expanded state.
                child: MergeSemantics(
                  child: Semantics(
                    expanded: _expanded,
                    child: TextButton(
                      onPressed: () => setState(() => _expanded = !_expanded),
                      child: Text(
                        _expanded ? l10n.collapseText : l10n.expandText,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
