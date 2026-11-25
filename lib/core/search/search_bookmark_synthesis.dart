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

/// Whether [applyFreeAccountBookmarkSynthesis] coerced an exact-tag query to
/// `partial_match_for_tags`, requiring local exact-tag matching on returned
/// entities so partial-tag false positives (e.g. `catgirl` for `cat`) are
/// filtered out.
bool needsLocalExactTagFilter(
  String keyword, {
  required SearchFilters filters,
  required bool isPremium,
}) {
  if (isPremium) return false;
  if (filters.normalizedTarget != SearchTarget.exactMatchForTags) return false;
  final min = filters.bookmarkMin;
  if (min == null || min < kBookmarkUsersIriTiers.first) return false;
  final trimmed = keyword.trim();
  return trimmed.isNotEmpty && !queryAlreadyHasUsersIri(trimmed);
}

final _whitespaceSplit = RegExp(r'[\s\u3000]+');

/// Client-side exact tag match compensation for free-account synthesized
/// queries. Matches each positive term (or `OR` group) case-insensitively
/// against any tag's raw `name` or `translatedName`, and rejects excluded
/// `-term` tokens.
bool matchesExactTagsLocally(
  String rawKeyword,
  Iterable<({String name, String? translatedName})> tags,
) {
  final tokens = rawKeyword
      .trim()
      .split(_whitespaceSplit)
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return true;

  final tagSet = <String>{};
  for (final tag in tags) {
    final name = tag.name.trim().toLowerCase();
    if (name.isNotEmpty) tagSet.add(name);
    final translated = tag.translatedName?.trim().toLowerCase();
    if (translated != null && translated.isNotEmpty) tagSet.add(translated);
  }

  String stripParens(String token) {
    var s = token;
    while (s.startsWith('(') && s.length > 1) {
      s = s.substring(1);
    }
    while (s.endsWith(')') && s.length > 1) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  // Group space-separated tokens into AND clauses where adjacent `A OR B`
  // terms form one OR group.
  final positiveGroups = <List<String>>[];
  final excluded = <String>[];
  var i = 0;
  while (i < tokens.length) {
    final token = tokens[i];
    if (token.toUpperCase() == 'OR') {
      i++;
      continue;
    }
    if (token.startsWith('-') && token.length > 1) {
      final term = stripParens(token.substring(1)).toLowerCase();
      if (term.isNotEmpty) excluded.add(term);
      i++;
      continue;
    }
    final group = <String>[];
    final first = stripParens(token).toLowerCase();
    if (first.isNotEmpty) group.add(first);
    while (i + 2 < tokens.length && tokens[i + 1].toUpperCase() == 'OR') {
      final next = stripParens(tokens[i + 2]).toLowerCase();
      if (next.isNotEmpty) group.add(next);
      i += 2;
    }
    if (group.isNotEmpty) positiveGroups.add(group);
    i++;
  }

  for (final term in excluded) {
    if (tagSet.contains(term)) return false;
  }
  for (final group in positiveGroups) {
    if (!group.any(tagSet.contains)) return false;
  }
  return true;
}
