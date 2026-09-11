import 'package:material_ui/material_ui.dart';

import '../theme/func_semantic_tokens.dart';

/// Shared tag chip: one presentation for every tag surface (illust detail,
/// novel info, search). Interactive instances go through [InkWell] so focus,
/// keyboard, and splash come from the framework instead of a bare
/// `GestureDetector`.
///
/// `blockMode` overlays the moderation badge: taps toggle the tag's blocked
/// state and the icon follows [blocked]; outside block mode taps run [onTap].
class TagChip extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    final surface = Material(
      color: tokens.surface,
      borderRadius: FuncShape.control,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: FuncShape.control,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: FuncSpacing.xs,
            horizontal: FuncSpacing.sm,
          ),
          child: Text(
            '#$label${translated != null ? ' $translated' : ''}',
            style: tokens.label,
          ),
        ),
      ),
    );
    final chip = Padding(
      padding: const EdgeInsets.all(FuncSpacing.xs),
      child: surface,
    );
    if (!blockMode) return chip;
    return Semantics(
      selected: blocked,
      child: Stack(
        children: [
          chip,
          Positioned(
            top: 0,
            right: 0,
            child: Icon(
              Icons.block,
              size: 15,
              color: blocked ? tokens.brand : tokens.contentTertiary,
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
