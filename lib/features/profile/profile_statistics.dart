import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../app/theme/func_semantic_tokens.dart';

@immutable
class ProfileStatisticData {
  const ProfileStatisticData({
    required this.id,
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  final String id;
  final IconData icon;
  final String label;
  final int value;
  final VoidCallback? onTap;
}

/// One about-page statistics row. A single semantic node announces the
/// label and value together.
class ProfileStatistic extends StatelessWidget {
  const ProfileStatistic({super.key, required this.statistic});

  final ProfileStatisticData statistic;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: ValueKey('profile-stat-${statistic.id}-about'),
      container: true,
      button: statistic.onTap != null,
      label: '${statistic.label}, ${AppFormat.count(context, statistic.value)}',
      onTap: statistic.onTap,
      child: ExcludeSemantics(
        child: ListTile(
          dense: true,
          leading: Icon(statistic.icon, size: 18),
          title: Text(statistic.label),
          trailing: Text(AppFormat.count(context, statistic.value)),
          onTap: statistic.onTap,
        ),
      ),
    );
  }
}

/// One counter in the profile header: a figure over its label.
@immutable
class ProfileHeaderStat {
  const ProfileHeaderStat({
    required this.id,
    required this.value,
    required this.label,
    this.onTap,
  });

  final String id;
  final int value;
  final String label;

  /// Opens the matching list; null leaves the stat as plain text.
  final VoidCallback? onTap;
}

/// The header's counters as figure-over-label blocks, start-aligned. Each
/// block is its own target, at least 48dp tall; on a narrow screen the
/// blocks wrap instead of overflowing.
class ProfileStatRow extends StatelessWidget {
  const ProfileStatRow({super.key, required this.stats});

  final List<ProfileHeaderStat> stats;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: FuncSpacing.sm,
    children: [for (final stat in stats) _ProfileStatBlock(stat: stat)],
  );
}

class _ProfileStatBlock extends StatelessWidget {
  const _ProfileStatBlock({required this.stat});

  final ProfileHeaderStat stat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final figure = AppFormat.count(context, stat.value);
    return Semantics(
      key: ValueKey('profile-stat-${stat.id}-header'),
      container: true,
      button: stat.onTap != null,
      label: '${stat.label}, $figure',
      onTap: stat.onTap,
      child: ExcludeSemantics(
        child: InkWell(
          borderRadius: FuncShape.control,
          onTap: stat.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FuncSpacing.xs,
                vertical: FuncSpacing.xxs,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    figure,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)
                        .tabular,
                  ),
                  Text(
                    stat.label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
