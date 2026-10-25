import 'package:material_ui/material_ui.dart';

import '../theme/func_semantic_tokens.dart';

/// A person as one card: the whole card is one button with a ripple that
/// runs [onTap] (open the profile, or the login when signed out), and
/// [trailing] (follow, account management) is a target of its own inside
/// it. A card that holds a button takes the ripple, not `PressScale`: a
/// press on the button would scale the card too (MOTION-06). Ink of the
/// card stays off while the inner button is pressed.
class PersonCard extends StatelessWidget {
  const PersonCard({
    super.key,
    required this.onTap,
    required this.child,
    this.tapHint,
    this.trailing,
    this.endPadding = padding,
    this.color,
  });

  /// The card's inner margin.
  static const padding = FuncSpacing.md;

  final VoidCallback onTap;

  /// Who it is: avatar and lines, read as the button's label.
  final Widget child;

  /// What a tap does, for screen readers.
  final String? tapHint;

  final Widget? trailing;

  /// The margin after [trailing]: an icon button takes
  /// `padding - EdgeIconButtons.glyphInset` so its glyph, not its target,
  /// ends on the content edge (LAYOUT-15).
  final double endPadding;

  /// The card's fill. Null takes the card theme's, one tier above the
  /// page; on a sheet, which already is that tier, pass the next one up.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final trailing = this.trailing;
    return Card(
      margin: EdgeInsets.zero,
      color: color,
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        container: true,
        button: true,
        onTapHint: tapHint,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                padding,
                padding,
                trailing == null ? padding : endPadding,
                padding,
              ),
              child: Row(
                children: [
                  Expanded(child: child),
                  if (trailing != null) ...[
                    const SizedBox(width: FuncSpacing.sm),
                    trailing,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
