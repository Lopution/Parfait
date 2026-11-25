import 'search_models.dart';

/// Pixiv's community-maintained bookmark milestone tag tiers, ordered from
/// lowest to highest. Free accounts cannot use the Premium-only
/// `bookmark_num_min` / `bookmark_num_max` wire filters, so tag searches
/// synthesize an `OR` group of matching `users入り` tags to stay server-indexed
/// before exact local count filtering refines the returned pages.
const List<int> kBookmarkUsersIriTiers = <int>[
  100,
  300,
  500,
  1000,
  3000,
  5000,
  10000,
  30000,
  50000,
  100000,
];

/// Quick-pick minimum bookmark presets shown in the search filter sheet.
const List<int> kBookmarkMinPresets = <int>[100, 500, 1000, 5000, 10000, 50000];

final _usersIriPattern = RegExp(r'users入り', caseSensitive: false);

/// Whether [target] searches Pixiv tag indexes where `users入り` tags apply.
bool canSynthesizeUsersIri(SearchTarget target) =>
    target == SearchTarget.partialMatchForTags ||
    target == SearchTarget.exactMatchForTags;

/// Whether [word] already contains an explicit `users入り` tag from the user.
bool queryAlreadyHasUsersIri(String word) => _usersIriPattern.hasMatch(word);

/// Computes the `users入り` tiers covering `[min, max]` without dropping works
/// whose bookmark count sits between milestones (e.g. `min: 2000` includes
/// `1000users入り` and above so 2,500-bookmark works tagged `1000users入り` are
/// still returned for exact local filtering).
List<int> usersIriTiersForRange({required int min, int? max}) {
  if (min < kBookmarkUsersIriTiers.first) return const [];
  var floorTier = kBookmarkUsersIriTiers.first;
  for (final tier in kBookmarkUsersIriTiers) {
    if (tier <= min) {
      floorTier = tier;
    } else {
      break;
    }
  }
  final tiers = <int>[
    for (final tier in kBookmarkUsersIriTiers)
      if (tier >= floorTier && (max == null || tier <= max)) tier,
  ];
  return tiers.isEmpty ? <int>[floorTier] : tiers;
}

/// Rewrites [query] for non-Premium tag searches with `bookmarkMin >= 100` by
/// appending a server-indexed `users入り` `OR` clause and coercing
/// `exact_match_for_tags` to `partial_match_for_tags` when synthesized.
///
/// Premium accounts and non-tag targets keep the original query unchanged.
Map<String, String> applyFreeAccountBookmarkSynthesis(
  Map<String, String> query, {
  required SearchFilters filters,
  required bool isPremium,
}) {
  if (isPremium) return query;
  final min = filters.bookmarkMin;
  if (min == null || min < kBookmarkUsersIriTiers.first) return query;
  final target = filters.normalizedTarget;
  if (!canSynthesizeUsersIri(target)) return query;
  final word = query['word']?.trim() ?? '';
  if (word.isEmpty || queryAlreadyHasUsersIri(word)) return query;

  final tiers = usersIriTiersForRange(min: min, max: filters.bookmarkMax);
  if (tiers.isEmpty) return query;

  final clause = tiers.length == 1
      ? '${tiers.first}users入り'
      : '(${tiers.map((t) => '${t}users入り').join(' OR ')})';
  final rewritten = Map<String, String>.of(query)
    ..['word'] = '$word $clause'
    ..remove('bookmark_num_min')
    ..remove('bookmark_num_max');
  if (target == SearchTarget.exactMatchForTags) {
    rewritten['search_target'] = SearchTarget.partialMatchForTags.wireValue;
  }
  return rewritten;
}
