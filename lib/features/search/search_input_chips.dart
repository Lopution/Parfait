import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/icons/app_icons.dart';
import '../../app/icons/ui_icons.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/display_actions.dart';
import '../../l10n/context.dart';

/// Compact boolean-operator helper bar rendered while typing tag queries
/// (`OR` insertion and quick `-` exclusion prefix).
class SearchOperatorBar extends StatelessWidget {
  const SearchOperatorBar({
    super.key,
    required this.onInsertOr,
    required this.onInsertExclude,
  });

  final VoidCallback onInsertOr;
  final VoidCallback onInsertExclude;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.xs,
        FuncSpacing.lg,
        0,
      ),
      child: Wrap(
        spacing: FuncSpacing.sm,
        runSpacing: FuncSpacing.xs,
        children: [
          ActionChip(
            key: const ValueKey('search-operator-or'),
            label: Text(l10n.searchInsertOr),
            onPressed: onInsertOr,
          ),
          ActionChip(
            key: const ValueKey('search-operator-exclude'),
            avatar: const Icon(UiIcons.removeCircle, size: 16),
            label: Text(l10n.searchExcludeTag),
            onPressed: onInsertExclude,
          ),
        ],
      ),
    );
  }
}

/// A recent or pinned search chip: tap searches it again, long press fills it,
/// secondary-click opens fill / exclude / pin actions, and the cross removes it.
class SearchHistoryChip extends StatelessWidget {
  const SearchHistoryChip({
    super.key,
    required this.keyword,
    required this.pinned,
    required this.onTap,
    required this.onLongPress,
    required this.onExclude,
    required this.onTogglePin,
    required this.onDeleted,
  });

  final String keyword;
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onExclude;
  final VoidCallback onTogglePin;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      onLongPressHint: l10n.searchSuggestionFill,
      child: GestureDetector(
        onLongPress: onLongPress,
        onSecondaryTapUp: (details) => unawaited(
          showDisplayActions(
            context,
            position: details.globalPosition,
            kind: details.kind,
            onLongPress: onLongPress,
            actions: [
              DisplayAction(
                icon: UiIcons.fillSuggestion,
                label: l10n.searchSuggestionFill,
                onSelected: onLongPress,
              ),
              DisplayAction(
                icon: UiIcons.removeCircle,
                label: l10n.searchExcludeTag,
                onSelected: onExclude,
              ),
              DisplayAction(
                icon: pinned ? UiIcons.pinOff : UiIcons.pin,
                label: pinned ? l10n.searchHistoryUnpin : l10n.searchHistoryPin,
                onSelected: onTogglePin,
              ),
            ],
          ),
        ),
        child: Tooltip(
          message: pinned ? l10n.searchHistoryUnpin : keyword,
          child: InputChip(
            avatar: Icon(pinned ? UiIcons.pin : AppIcons.history),
            label: Text(keyword),
            onPressed: onTap,
            onDeleted: onDeleted,
            deleteButtonTooltipMessage: l10n.searchHistoryRemove,
          ),
        ),
      ),
    );
  }
}
