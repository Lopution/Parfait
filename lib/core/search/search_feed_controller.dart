import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/illust_entity.dart';
import '../entity/illust_store.dart';
import '../novel/novel_store.dart';
import '../paging/paged_feed_controller.dart';
import '../user/user_store.dart';
import 'search_models.dart';
import 'search_repository.dart';

/// One independent result state for one typed query and account.
class _SearchFeedController extends PagedFeedController {
  _SearchFeedController(this.query);

  final SearchQuery query;

  @override
  String get feedKey => 'search:${query.cacheKey}';

  /// C9: search results are discovery content. Only illust/manga queries
  /// have local-block semantics; novel/user searches stay unfiltered.
  @override
  bool get localFilterEnabled => query is IllustSearchQuery;

  /// Client-side enforcement for filters the server does not honor:
  /// `bookmark_num_min/max` are Premium-only (free accounts are silently
  /// ignored, per Shaft's verification) and "only AI" has no wire value at
  /// all. Both predicates re-run against the returned entities so the
  /// filter holds on every account tier — idempotent when the server did
  /// apply them.
  @override
  List<int> filterPageIds(
    List<int> ids, {
    Map<int, IllustEntity>? incomingIllusts,
  }) {
    final visible = super.filterPageIds(ids, incomingIllusts: incomingIllusts);
    final query = this.query;
    if (query is! IllustSearchQuery) return visible;
    final filters = query.filters;
    final aiOnly = filters.aiFilter == SearchAiFilter.only;
    final min = filters.bookmarkMin;
    final max = filters.bookmarkMax;
    if (!aiOnly && min == null && max == null) return visible;
    final store = ref.read(illustStoreProvider);
    return [
      for (final id in visible)
        if (_passesSearchPredicates(
          incomingIllusts?[id] ?? store.get(id),
          aiOnly: aiOnly,
          min: min,
          max: max,
        ))
          id,
    ];
  }

  bool _passesSearchPredicates(
    IllustEntity? entity, {
    required bool aiOnly,
    required int? min,
    required int? max,
  }) {
    // Entities not yet in the store are kept — same no-evidence rule as
    // the shared predicate.
    if (entity == null) return true;
    if (aiOnly && !entity.isAi) return false;
    if (min != null && entity.totalBookmarks < min) return false;
    if (max != null && entity.totalBookmarks > max) return false;
    return true;
  }

  @override
  int get filterMinVisible => 24;

  @override
  int get filterMaxRefillPages => 3;

  @override
  Future<PagedFeedState> build() {
    // Account identity and its premium flag both decide the search route
    // (premium-only sorts reroute to popular-preview for free accounts).
    ref.watch(
      accountStoreProvider.select(
        (async) => (async.value?.current?.id, async.value?.current?.isPremium),
      ),
    );
    return super.build();
  }

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) {
    final repository = ref.read(searchRepositoryProvider);
    return switch (query) {
      final IllustSearchQuery value => _fetchIllustForContext(
        repository,
        value,
        context,
      ),
      final NovelSearchQuery value => _fetchNovelForContext(
        repository,
        value,
        context,
      ),
      final UserSearchQuery value => _fetchUsersForContext(
        repository,
        value,
        context,
      ),
    };
  }

  Future<FeedPage> _fetchIllustForContext(
    SearchRepository repository,
    IllustSearchQuery query,
    FeedRequestContext context,
  ) async {
    final store = ref.read(illustStoreProvider);
    final bookmarkRevision = store.bookmarkRevisionNow();
    final page = await repository.searchIllust(
      query,
      cursor: context.cursor,
      cancelToken: context.cancelToken,
    );
    return FeedPage(
      ids: [for (final item in page.illusts) item.id],
      nextCursor: page.nextUrl,
      incomingIllusts: {for (final item in page.illusts) item.id: item},
      commit: (_) => store.mergeAll(
        page.illusts,
        bookmarkSnapshotRevision: bookmarkRevision,
      ),
    );
  }

  Future<FeedPage> _fetchNovelForContext(
    SearchRepository repository,
    NovelSearchQuery query,
    FeedRequestContext context,
  ) async {
    final page = await repository.searchNovel(
      query,
      cursor: context.cursor,
      cancelToken: context.cancelToken,
    );
    final store = ref.read(novelStoreProvider.notifier);
    return FeedPage(
      ids: [for (final item in page.novels) item.id],
      nextCursor: page.nextUrl,
      commit: (_) => store.mergeAll(page.novels),
    );
  }

  Future<FeedPage> _fetchUsersForContext(
    SearchRepository repository,
    UserSearchQuery query,
    FeedRequestContext context,
  ) async {
    final store = ref.read(userStoreProvider.notifier);
    final followRevision = store.followRevisionNow();
    final page = await repository.searchUsers(
      query,
      cursor: context.cursor,
      cancelToken: context.cancelToken,
    );
    return FeedPage(
      ids: [for (final item in page.users) item.id],
      nextCursor: page.nextUrl,
      commit: (_) =>
          store.mergeAll(page.users, followSnapshotRevision: followRevision),
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null || rawCursor.isEmpty) return null;
    return ref
            .read(searchRepositoryProvider)
            .validateCursor(query, cursor: rawCursor)
        ? rawCursor
        : null;
  }
}

final searchFeedProvider =
    AsyncNotifierProvider.family<
      _SearchFeedController,
      PagedFeedState,
      SearchQuery
    >(_SearchFeedController.new);
