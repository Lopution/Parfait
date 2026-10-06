import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/accessibility.dart';

/// Rewrites `MediaQuery.accessibleNavigation` to the real touch-exploration
/// flag for everything below it.
///
/// The engine sets that flag when ANY assistive service queries a node (GKD
/// pins it true for the whole session), so material_ui internals and the
/// app's own reads would treat an ad skipper as a screen reader. Below this
/// scope the flag means "TalkBack is exploring". Until Android's stream
/// reports, and on iOS where the engine flag already means VoiceOver, the
/// engine value passes through.
class TouchExplorationScope extends ConsumerWidget {
  const TouchExplorationScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = MediaQuery.of(context);
    final reported = ref.watch(touchExplorationProvider).value;
    return MediaQuery(
      data: data.copyWith(
        accessibleNavigation: reported ?? data.accessibleNavigation,
      ),
      child: child,
    );
  }
}
