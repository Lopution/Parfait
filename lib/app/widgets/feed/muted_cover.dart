import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Session-local set of muted works the user has revealed by tapping the
/// blurred card. Revealing is presentation-only: it never touches the
/// MuteStore, and the set resets with the app session.
class RevealedMuteIds extends Notifier<Set<int>> {
  @override
  Set<int> build() => const {};

  void reveal(int illustId) => state = {...state, illustId};
}

final revealedMuteIdsProvider = NotifierProvider<RevealedMuteIds, Set<int>>(
  RevealedMuteIds.new,
);

/// The blur+reveal card variant (Shaft-style muted object): the artwork is
/// blurred under a labelled cover; tapping reveals it in place. Rendered
/// instead of the normal preview when `muteHitFor` reports a hit and the
/// user keeps the default blur display mode.
class MutedCover extends StatelessWidget {
  const MutedCover({super.key, required this.child, required this.reasonLabel});

  /// The blurred content (the card's image stack).
  final Widget child;

  /// Why the work is muted (tag name / author name / work title).
  final String reasonLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: child,
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(12)),
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
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
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
