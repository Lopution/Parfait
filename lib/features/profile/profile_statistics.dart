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

/// One link in the profile header's statistics line. [text] is the
/// visible, already formatted label ("12 关注").
@immutable
class ProfileHeaderStat {
  const ProfileHeaderStat({required this.id, required this.text, this.onTap});

  final String id;
  final String text;

  /// Opens the matching list; null leaves the stat as plain text.
  final VoidCallback? onTap;
}

/// The header's statistics as one line of text links separated by " · ".
/// Each link is its own 48dp target; on a narrow screen the line wraps
/// instead of overflowing.
class ProfileStatLine extends StatelessWidget {
  const ProfileStatLine({super.key, required this.stats});

  final List<ProfileHeaderStat> stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < stats.length; i++) ...[
          if (i > 0)
            ExcludeSemantics(
              child: Text(
                '·',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          _ProfileStatLink(stat: stats[i]),
        ],
      ],
    );
  }
}

class _ProfileStatLink extends StatelessWidget {
  const _ProfileStatLink({required this.stat});

  final ProfileHeaderStat stat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      key: ValueKey('profile-stat-${stat.id}-header'),
      container: true,
      button: stat.onTap != null,
      label: stat.text,
      onTap: stat.onTap,
      child: ExcludeSemantics(
        child: InkWell(
          borderRadius: FuncShape.control,
          onTap: stat.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinInteractiveDimension,
            ),
            // Centred in the 48dp target; a label wider than the line wraps.
            child: Align(
              widthFactor: 1,
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.xs),
                child: Text(
                  stat.text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
