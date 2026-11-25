import 'package:material_ui/material_ui.dart';

import '../layout/input_modality.dart';
import '../motion/motion_tokens.dart';
import '../motion/press_scale.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';
import 'feed/feed_text_warmup.dart';
import 'middle_click_region.dart';
import '../icons/app_icons.dart';

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

/// Shared tag chip: one presentation for every tag surface (illust detail,
/// novel info, search) — a neutral pill whose tap target extends to 48dp.
/// The accent stays off it (THEME-07); the hairline keeps it visible on a
/// sheet of its own fill (THEME-09). Interactive instances go through [InkWell] so focus, keyboard and
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
    this.onSecondaryTapAt,
    this.onMiddleClick,
    this.blockMode = false,
    this.blocked = false,
  });

  final String label;
  final String? translated;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// The secondary click's global position, where the host offers its
  /// actions beside the pointer on a PC (R11); without it the right-click
  /// runs [onLongPress].
  final ValueChanged<Offset>? onSecondaryTapAt;
  final VoidCallback? onMiddleClick;
  final bool blockMode;
  final bool blocked;

  /// The chip's line as it lays it out under [context], on a page's
  /// Material (`bodyMedium`), for [FeedTextWarmup].
  static WarmText warmText(
    BuildContext context, {
    required String label,
    String? translated,
  }) => (
    span: TextSpan(
      style: warmStyle(
        context,
        null,
        inherited: Theme.of(context).textTheme.bodyMedium,
      ),
      children: [_span(FuncSemanticTokens.of(context), label, translated)],
    ),
    locale: Localizations.maybeLocaleOf(context),
    strutStyle: null,
  );

  /// The tag in neutral primary content ink, then its translation in the
  /// secondary colour (`THEME-07`: tag chips stay neutral; only keyboard focus
  /// rings them in the accent).
  static TextSpan _span(
    FuncSemanticTokens tokens,
    String label,
    String? translated,
  ) => TextSpan(
    text: '#$label',
    style: tokens.label.copyWith(color: tokens.contentPrimary),
    children: [
      if (translated != null)
        TextSpan(
          text: ' $translated',
          style: tokens.caption.copyWith(color: tokens.contentSecondary),
        ),
    ],
  );

  @override
  State<TagChip> createState() => _TagChipState();
}

class _TagChipState extends State<TagChip> {
  /// Keyboard focus thickens the outline in place of the ink highlight.
  var _focused = false;
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final interactive = widget.onTap != null || widget.onLongPress != null;
    final hovered = interactive && _hovered;
    final pill = DecoratedBox(
      decoration: ShapeDecoration(
        color: hovered ? tokens.surfaceRaised : tokens.surface,
        shape: StadiumBorder(
          side: _focused
              ? BorderSide(color: colors.primary, width: 2)
              : BorderSide(
                  color: hovered
                      ? colors.onSurface.withValues(alpha: 0.22)
                      : tokens.divider,
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
          // One line: a tag too long for the row loses its end, the
          // translation first, without word-break pre-truncation when space
          // still remains in the row.
          child: Center(
            widthFactor: 1,
            child: Text.rich(
              TagChip._span(tokens, widget.label, widget.translated),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
    Widget chip = PressScale(
      scale: MotionTokens.pillPressScale,
      enabled: interactive,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onSecondaryTapUp: widget.onSecondaryTapAt == null
            ? null
            : (details) => widget.onSecondaryTapAt!(details.globalPosition),
        onSecondaryTap: widget.onSecondaryTapAt == null
            ? widget.onLongPress
            : null,
        onHover: interactive
            ? (isHovered) => setState(() => _hovered = isHovered)
            : null,
        onFocusChange: (focused) => setState(() => _focused = focused),
        // A long-press host plays its own AppHaptics role; the ink
        // response's vibration would double it.
        enableFeedback: widget.onLongPress == null,
        splashFactory: NoSplash.splashFactory,
        overlayColor: const WidgetStatePropertyAll(FuncTokens.transparent),
        child: Padding(padding: _hitMargin, child: pill),
      ),
    );
    if (widget.onMiddleClick != null) {
      chip = MiddleClickRegion(
        onMiddleClick: widget.onMiddleClick,
        child: chip,
      );
    }
    final modality =
        InputModalityScope.maybeOf(context) ??
        defaultInputModalityFor(Theme.of(context).platform);
    Widget wrap(Widget child) => modality == InputModality.pointer
        ? child
        : SelectionContainer.disabled(child: child);
    if (!widget.blockMode) return wrap(chip);
    return wrap(
      Semantics(
        selected: widget.blocked,
        child: Stack(
          children: [
            chip,
            Positioned(
              top: _hitMargin.top - FuncSpacing.xs,
              right: 0,
              child: IgnorePointer(
                child: Icon(
                  AppIcons.banFilled,
                  size: 15,
                  color: widget.blocked
                      ? Theme.of(context).colorScheme.primary
                      : tokens.contentTertiary,
                ),
              ),
            ),
          ],
        ),
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
