import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../core/illust/ranking_repository.dart';
import '../../l10n/context.dart';

/// Opens the ranking date picker on [date] (null is the latest). Days
/// outside pixiv's ranking history (before the first ranking, today or
/// later in Japan) cannot be picked.
Future<void> pickRankingDate(
  BuildContext context, {
  required DateTime? date,
  required ValueChanged<DateTime> onPicked,
}) async {
  final lastDate = rankingLastDate();
  final picked = await showDatePicker(
    context: context,
    firstDate: rankingFirstDate,
    lastDate: lastDate,
    initialDate: date ?? lastDate,
  );
  if (picked != null) onPicked(picked);
}

/// The sheet's date row value: "latest" or the ranking day on screen.
String rankingDateText(BuildContext context, DateTime? date) => switch (date) {
  null => context.l10n.rankingLatest,
  final date => AppFormat.date(context, date),
};

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
        // The button's label, not its padding, ends on the margin.
        padding: const EdgeInsetsDirectional.only(
          start: FuncSpacing.lg,
          end: FuncSpacing.lg - EdgeIconButtons.glyphInset,
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
