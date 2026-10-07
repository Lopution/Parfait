import 'package:flutter/foundation.dart';

import '../platform/intent_router.dart';
import 'search_models.dart';

/// What a search input opens directly instead of searching.
enum SearchShortcutKind { illust, novel, user }

/// A work or user the input names by id or by pixiv link.
@immutable
class SearchShortcut {
  const SearchShortcut(this.kind, this.id);

  final SearchShortcutKind kind;
  final int id;

  @override
  bool operator ==(Object other) =>
      other is SearchShortcut && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'SearchShortcut(${kind.name}, $id)';
}

/// Longest bare number read as an id; pixiv ids are well below this.
const _maxIdDigits = 12;
final _bareId = RegExp('^[0-9]{1,$_maxIdDigits}\$');

/// The shortcut [input] stands for, or null when it is a plain query.
///
/// A pixiv link opens what it points at whatever [type] is selected. A
/// bare number is an id of the selected [type]: an illust or manga, a
/// novel, or a user.
SearchShortcut? searchShortcutFor(String input, SearchResultType type) {
  final text = input.trim();
  if (_bareId.hasMatch(text)) {
    final id = int.parse(text);
    if (id <= 0) return null;
    return SearchShortcut(switch (type) {
      SearchResultType.illust => SearchShortcutKind.illust,
      SearchResultType.novel => SearchShortcutKind.novel,
      SearchResultType.user => SearchShortcutKind.user,
    }, id);
  }
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme) return null;
  final novel = _novelLink(uri);
  if (novel != null) return SearchShortcut(SearchShortcutKind.novel, novel);
  return switch (IntentRouter.route(uri)) {
    IllustRoute(:final illustId) => SearchShortcut(
      SearchShortcutKind.illust,
      illustId,
    ),
    UserRoute(:final userId) => SearchShortcut(SearchShortcutKind.user, userId),
    AccountCallbackRoute() || UnknownRoute() || ForeignUri() => null,
  };
}

/// `https://www.pixiv.net/novel/show.php?id=<id>`, with or without `www.`
/// or a language prefix. App deep links never carry novels, so the parsing
/// lives here rather than in [IntentRouter].
int? _novelLink(Uri uri) {
  if (uri.scheme != 'https' && uri.scheme != 'http') return null;
  final host = uri.host.toLowerCase();
  if (host != 'pixiv.net' && host != 'www.pixiv.net') return null;
  var segments = uri.pathSegments;
  if (segments.length == 3 && segments.first.length == 2) {
    segments = segments.sublist(1);
  }
  if (segments.length != 2 ||
      segments[0] != 'novel' ||
      segments[1] != 'show.php') {
    return null;
  }
  final id = int.tryParse(uri.queryParameters['id'] ?? '');
  return id == null || id <= 0 ? null : id;
}
