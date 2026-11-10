import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/fit_label.dart';

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
          // Icon and value sit on the content edges like the entries
          // above.
          contentPadding: EdgeInsets.zero,
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

  /// The width [stats] take on one line under [context].
  static double widthOf(BuildContext context, List<ProfileHeaderStat> stats) {
    final theme = Theme.of(context);
    final ambient = DefaultTextStyle.of(context).style;
    double measure(String text, TextStyle? style) => LabelFit.measureLabel(
      text,
      LabelFit.paintedStyle(context, ambient.merge(style)),
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
      locale: Localizations.maybeLocaleOf(context),
    );
    var width = FuncSpacing.sm * math.max(0, stats.length - 1);
    for (final stat in stats) {
      width +=
          2 * FuncSpacing.xs +
          math.max(
            measure(
              AppFormat.count(context, stat.value),
              _ProfileStatBlock.figureStyle(theme),
            ),
            measure(stat.label, _ProfileStatBlock.labelStyle(theme)),
          );
    }
    return width;
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: FuncSpacing.sm,
    children: [for (final stat in stats) _ProfileStatBlock(stat: stat)],
  );
}

class _ProfileStatBlock extends StatelessWidget {
  const _ProfileStatBlock({required this.stat});

  final ProfileHeaderStat stat;

  static TextStyle? figureStyle(ThemeData theme) =>
      theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700).tabular;

  static TextStyle? labelStyle(ThemeData theme) => theme.textTheme.labelMedium
      ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

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
                  Text(figure, style: figureStyle(theme)),
                  Text(stat.label, style: labelStyle(theme)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
