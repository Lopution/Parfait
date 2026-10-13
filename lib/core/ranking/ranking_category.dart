/// What the ranking pages, the category sheet and the local block need from
/// a ranking mode, illust and novel alike.
library;

/// The content rating a ranking category is limited to.
enum RankingRating { allAges, r18, r18g }

/// A ranking mode the user can show, hide and reorder. Implemented by the
/// illust and novel mode enums; `name` is the route value, [apiValue] the
/// request and persisted value.
abstract interface class RankingCategory implements Enum {
  String get apiValue;

  /// The l10n key of the tab label.
  String get labelKey;
  RankingRating get rating;
  bool get isAi;
}

/// Whether the local block (browse settings) hides [category]. R-18G counts
/// as R-18.
bool isRankingCategoryBlocked(
  RankingCategory category, {
  required bool blockR18,
  required bool blockAI,
}) =>
    (blockR18 && category.rating != RankingRating.allAges) ||
    (blockAI && category.isAi);

/// The categories a ranking page shows: [shown] minus the blocked ones.
/// [routeMode] — a deep link to a hidden category — goes first for this
/// visit without being saved; a blocked one does not. When the block
/// leaves nothing, [fallback] (an all-ages category) is shown alone.
List<M> visibleRankingCategories<M extends RankingCategory>(
  List<M> shown, {
  required bool blockR18,
  required bool blockAI,
  required M fallback,
  M? routeMode,
}) {
  bool blocked(M mode) =>
      isRankingCategoryBlocked(mode, blockR18: blockR18, blockAI: blockAI);
  final visible = [
    if (routeMode != null && !shown.contains(routeMode) && !blocked(routeMode))
      routeMode,
    for (final mode in shown)
      if (!blocked(mode)) mode,
  ];
  return visible.isEmpty ? [fallback] : visible;
}

/// The category a ranking page opens on: the route's, then the last one
/// viewed, then the first visible.
M initialRankingCategory<M extends RankingCategory>(
  List<M> visible, {
  M? routeMode,
  M? lastViewed,
}) {
  if (routeMode != null && visible.contains(routeMode)) return routeMode;
  if (lastViewed != null && visible.contains(lastViewed)) return lastViewed;
  return visible.first;
}
