import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/func_semantic_tokens.dart';

/// Session-local set of muted works the user has revealed by tapping the
/// blurred card. Revealing is presentation-only: it never touches the
/// MuteStore, and the set resets with the app session.
class RevealedMuteIds extends Notifier<Set<int>> {
  @override
  Set<int> build() => const {};

  void reveal(int id) => state = {...state, id};
}

final revealedMuteIdsProvider = NotifierProvider<RevealedMuteIds, Set<int>>(
  RevealedMuteIds.new,
);

/// [revealedMuteIdsProvider] for novel rows: a novel may share an
/// illust's id.
final revealedMutedNovelIdsProvider =
    NotifierProvider<RevealedMuteIds, Set<int>>(RevealedMuteIds.new);

/// The blur+reveal card variant for a muted object: the artwork, blurred
/// once at decode, under a labelled cover; tapping reveals it in place.
/// Rendered instead of the normal preview when `muteHitFor` reports a hit
/// and the user keeps the default blur display mode.
class MutedCover extends StatelessWidget {
  const MutedCover({super.key, required this.child, required this.reasonLabel});

  /// How strongly a muted work's image is blurred ([PixivImage.blur]), in
  /// logical pixels.
  static const blurSigma = 10.0;

  /// The card's image, blurred by [blurSigma] and clipped to the card.
  final Widget child;

  /// Why the work is muted (tag name / author name / work title).
  final String reasonLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: FuncShape.card,
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.visibility_off_outlined,
                    color: scheme.onSurfaceVariant,
                    size: 30,
                  ),
                  const SizedBox(height: FuncSpacing.xs),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FuncSpacing.md,
                    ),
                    child: Text(
                      reasonLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
