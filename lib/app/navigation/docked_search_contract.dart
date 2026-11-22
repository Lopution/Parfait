import 'package:flutter/widgets.dart';

import '../../core/search/search_models.dart';
import '../../core/search/search_shortcut.dart';

/// What the docked search panel decided when it closed.
sealed class DockedSearchOutcome {
  const DockedSearchOutcome();
}

/// The user searched [query]: the host moves to the results (R10).
final class DockedSearchSubmitted extends DockedSearchOutcome {
  const DockedSearchSubmitted(this.query);

  final SearchQuery query;
}

/// The window narrowed to the phone layout: carry the draft to the full
/// input page instead (R10). The keyword is exactly as typed — handing it
/// over must not trim it — and the filter drafts come along too.
final class DockedSearchNarrowed extends DockedSearchOutcome {
  const DockedSearchNarrowed({
    required this.keyword,
    required this.type,
    this.illustFilters,
    this.novelFilters,
  });

  final String keyword;
  final SearchResultType type;
  final IllustSearchFilters? illustFilters;
  final NovelSearchFilters? novelFilters;
}

/// The user typed a pixiv id or link: open the work or author it names.
final class DockedSearchShortcut extends DockedSearchOutcome {
  const DockedSearchShortcut(this.shortcut);

  final SearchShortcut shortcut;
}

/// Callback that opens the desktop docked search panel without coupling
/// [route_search_facade] directly to `features/search/`.
typedef DockedSearchPresenter =
    Future<DockedSearchOutcome?> Function(
      BuildContext context, {
      required Rect anchor,
      Rect? Function()? anchorOf,
      String initialKeyword,
      SearchResultType type,
      IllustSearchFilters? initialIllustFilters,
      NovelSearchFilters? initialNovelFilters,
    });

DockedSearchPresenter? _presenter;

/// Registers the docked search presenter once from router assembly (`routes.dart`).
void registerDockedSearchPresenter(DockedSearchPresenter presenter) {
  _presenter = presenter;
}

/// Opens the registered docked search panel, or returns `null` when none was
/// registered (e.g. a narrow unit test without the full app router).
Future<DockedSearchOutcome?> presentDockedSearch(
  BuildContext context, {
  required Rect anchor,
  Rect? Function()? anchorOf,
  String initialKeyword = '',
  SearchResultType type = SearchResultType.illust,
  IllustSearchFilters? initialIllustFilters,
  NovelSearchFilters? initialNovelFilters,
}) {
  final presenter = _presenter;
  if (presenter == null) return Future<DockedSearchOutcome?>.value();
  return presenter(
    context,
    anchor: anchor,
    anchorOf: anchorOf,
    initialKeyword: initialKeyword,
    type: type,
    initialIllustFilters: initialIllustFilters,
    initialNovelFilters: initialNovelFilters,
  );
}
