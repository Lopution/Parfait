import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../core/illust/ranking_repository.dart';
import '../../l10n/context.dart';

/// App-bar action that opens the ranking date picker. Days outside pixiv's
/// ranking history (before the first ranking, today or later in Japan)
/// cannot be picked.
class RankingDateButton extends StatelessWidget {
  const RankingDateButton({
    super.key,
    required this.date,
    required this.onChanged,
  });

  /// The ranking day on screen; null is the latest.
  final DateTime? date;
  final ValueChanged<DateTime> onChanged;

  Future<void> _pick(BuildContext context) async {
    final lastDate = rankingLastDate();
    final picked = await showDatePicker(
      context: context,
      firstDate: rankingFirstDate,
      lastDate: lastDate,
      initialDate: date ?? lastDate,
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: context.l10n.rankingPickDate,
      onPressed: () => _pick(context),
      icon: const Icon(Icons.calendar_month_outlined),
    );
  }
}

/// The bar under the mode tabs while a past ranking is shown: which day it
/// is, and the way back to the latest ranking. It sits at the top of the
/// page body rather than in the app bar so a long label (large text, narrow
/// screens) can wrap instead of being cut.
class RankingDateBar extends StatelessWidget {
  const RankingDateBar({
    super.key,
    required this.date,
    required this.onBackToLatest,
  });

  static const minHeight = 40.0;

  final DateTime date;
  final VoidCallback onBackToLatest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: FuncSpacing.lg,
          end: FuncSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.rankingDateLabel(AppFormat.date(context, date)),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(
              onPressed: onBackToLatest,
              child: Text(context.l10n.rankingBackToLatest),
            ),
          ],
        ),
      ),
    );
  }
}
