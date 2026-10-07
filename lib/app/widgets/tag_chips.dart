import 'package:material_ui/material_ui.dart';

import '../motion/motion_tokens.dart';
import '../motion/press_scale.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';

/// Visible height of a tag pill; text scaling may grow it.
const _pillHeight = 32.0;

/// Margin around the pill that still belongs to the tap target. Vertically
/// it lifts the 32dp pill to a [kMinInteractiveDimension] target (8 + 32 +
/// 8); horizontally neighbouring chips touch, so the gap between two tags
/// is half one chip's target and half the other's — no dead zone.
const _hitMargin = EdgeInsets.symmetric(
  vertical: FuncSpacing.sm,
  horizontal: FuncSpacing.xs,
);

/// Brand tint of the pill's fill and outline.
const _fillAlpha = 0.08;
const _outlineAlpha = 0.28;

/// Shared tag chip: one presentation for every tag surface (illust detail,
/// novel info, search) — a brand-tinted pill whose tap target extends to
/// 48dp. Interactive instances go through [InkWell] so focus, keyboard and
/// semantics come from the framework; press feedback is a scale, not ink,
/// since ink would fill the whole target rather than the pill.
///
/// `blockMode` overlays the moderation badge: taps toggle the tag's blocked
/// state and the icon follows [blocked]; outside block mode taps run [onTap].
class TagChip extends StatefulWidget {
  const TagChip({
    super.key,
    required this.label,
    this.translated,
    this.onTap,
    this.onLongPress,
    this.blockMode = false,
    this.blocked = false,
  });

  final String label;
  final String? translated;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool blockMode;
  final bool blocked;

  @override
  State<TagChip> createState() => _TagChipState();
}

class _TagChipState extends State<TagChip> {
  /// Keyboard focus thickens the outline in place of the ink highlight.
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    final translated = widget.translated;
    final pill = DecoratedBox(
      decoration: ShapeDecoration(
        color: tokens.brand.withValues(alpha: _fillAlpha),
        shape: StadiumBorder(
          side: _focused
              ? BorderSide(color: tokens.brand, width: 2)
              : BorderSide(
                  color: tokens.brand.withValues(alpha: _outlineAlpha),
                ),
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _pillHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FuncSpacing.md,
            vertical: FuncSpacing.xs,
          ),
          child: Center(
            widthFactor: 1,
            child: Text.rich(
              TextSpan(
                text: '#${widget.label}',
                style: tokens.label.copyWith(color: tokens.contentPrimary),
                children: [
                  if (translated != null)
                    TextSpan(
                      text: ' $translated',
                      style: TextStyle(color: tokens.contentSecondary),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final chip = PressScale(
      scale: MotionTokens.pillPressScale,
      enabled: widget.onTap != null || widget.onLongPress != null,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onFocusChange: (focused) => setState(() => _focused = focused),
        // A long-press host plays its own AppHaptics role; the ink
        // response's vibration would double it.
        enableFeedback: widget.onLongPress == null,
        splashFactory: NoSplash.splashFactory,
        overlayColor: const WidgetStatePropertyAll(FuncTokens.transparent),
        child: Padding(padding: _hitMargin, child: pill),
      ),
    );
    if (!widget.blockMode) return chip;
    return Semantics(
      selected: widget.blocked,
      child: Stack(
        children: [
          chip,
          Positioned(
            top: _hitMargin.top - FuncSpacing.xs,
            right: 0,
            child: IgnorePointer(
              child: Icon(
                Icons.block,
                size: 15,
                color: widget.blocked ? tokens.brand : tokens.contentTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared wrap for a list of tag chips; pages pass typed chips, never raw
/// per-page containers.
class TagChips extends StatelessWidget {
  const TagChips({super.key, required this.children});

  final List<TagChip> children;

  @override
  Widget build(BuildContext context) => Wrap(children: children);
}
