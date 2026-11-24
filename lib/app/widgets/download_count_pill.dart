import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/download/download_providers.dart';
import '../format/app_format.dart';
import '../theme/func_semantic_tokens.dart';

/// Restrained live active + failed download count indicator for [ShellRail].
///
/// Renders nothing when no [ProviderScope] is mounted above (for example, bare
/// layout tests) or when both active and failed counts are zero. Uses muted
/// tonal surfaces rather than loud warning red.
class DownloadCountPill extends StatelessWidget {
  const DownloadCountPill({super.key});

  @override
  Widget build(BuildContext context) {
    if (context.findAncestorWidgetOfExactType<UncontrolledProviderScope>() ==
        null) {
      return const SizedBox.shrink();
    }
    return const _LiveDownloadCountPill();
  }
}

class _LiveDownloadCountPill extends ConsumerWidget {
  const _LiveDownloadCountPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats =
        ref.watch(downloadStatsProvider).value ??
        (active: 0, failed: 0, total: 0);
    final attention = stats.active + stats.failed;
    if (attention <= 0) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final bg = stats.active > 0
        ? colors.primaryContainer
        : colors.surfaceContainerHighest;
    final fg = stats.active > 0
        ? colors.onPrimaryContainer
        : colors.onSurfaceVariant;
    return DecoratedBox(
      key: const Key('rail-downloads-count'),
      decoration: BoxDecoration(color: bg, borderRadius: FuncShape.pill),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.sm),
        child: Text(
          AppFormat.count(context, attention),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: fg,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Compact rail icon wrapper attaching a restrained download count badge when
/// active or failed downloads exist.
class DownloadCountBadgeIcon extends StatelessWidget {
  const DownloadCountBadgeIcon({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled ||
        context.findAncestorWidgetOfExactType<UncontrolledProviderScope>() ==
            null) {
      return child;
    }
    return _LiveDownloadCountBadgeIcon(child: child);
  }
}

class _LiveDownloadCountBadgeIcon extends ConsumerWidget {
  const _LiveDownloadCountBadgeIcon({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats =
        ref.watch(downloadStatsProvider).value ??
        (active: 0, failed: 0, total: 0);
    final attention = stats.active + stats.failed;
    if (attention <= 0) return child;
    final colors = Theme.of(context).colorScheme;
    return Badge(
      key: const Key('rail-downloads-count'),
      backgroundColor: stats.active > 0
          ? colors.primaryContainer
          : colors.surfaceContainerHighest,
      textColor: stats.active > 0
          ? colors.onPrimaryContainer
          : colors.onSurfaceVariant,
      label: Text(AppFormat.count(context, attention)),
      child: child,
    );
  }
}
