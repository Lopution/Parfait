import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/illust_entity.dart';
import '../entity/illust_store.dart';
import '../illust/illust_snapshot_codec.dart';
import '../novel/novel_entity.dart';
import '../novel/novel_store.dart';
import '../novel/novel_snapshot_codec.dart';
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

  @override
  FeedSnapshotCodec? get snapshotCodec => switch (query) {
    IllustSearchQuery() => const IllustSnapshotCodec(),
    NovelSearchQuery() => const NovelSnapshotCodec(),
    _ => null,
  };

  /// C9: search results are discovery content. The local-block predicate is
  /// illust-entity based, but novel queries still need the refill loop for
  /// their own client-side predicates — user queries stay unfiltered.
  @override
  bool get localFilterEnabled => query is! UserSearchQuery;

  /// Client-side enforcement for filters the server does not honor:
  /// `bookmark_num_min/max` are Premium-only (free accounts are silently
  /// ignored) and "only AI" has no wire value at
  /// all. Both predicates re-run against the returned entities so the
  /// filter holds on every account tier — idempotent when the server did
  /// apply them. Novel queries apply the same rule against `novel_ai_type`/
  /// `total_bookmarks` and skip the illust-only C9 layer.
  @override
  List<int> filterPageIds(
    List<int> ids, {
    Map<int, IllustEntity>? incomingIllusts,
    Map<int, NovelEntity>? incomingNovels,
  }) {
    final query = this.query;
    return switch (query) {
      IllustSearchQuery(:final filters) => _filterIllustIds(
        super.filterPageIds(ids, incomingIllusts: incomingIllusts),
        filters,
        incomingIllusts: incomingIllusts,
      ),
      NovelSearchQuery(:final filters) => _filterNovelIds(
        ids,
        filters,
        incomingNovels: incomingNovels,
      ),
      _ => ids,
    };
  }

  List<int> _filterIllustIds(
    List<int> ids,
    IllustSearchFilters filters, {
    Map<int, IllustEntity>? incomingIllusts,
  }) {
    final aiOnly = filters.aiFilter == SearchAiFilter.only;
    final min = filters.bookmarkMin;
    final max = filters.bookmarkMax;
    if (!aiOnly && min == null && max == null) return ids;
    final store = ref.read(illustStoreProvider);
    return [
      for (final id in ids)
        if (_passesIllustPredicates(
          incomingIllusts?[id] ?? store.get(id),
          aiOnly: aiOnly,
          min: min,
          max: max,
        ))
          id,
    ];
  }

  bool _passesIllustPredicates(
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

  List<int> _filterNovelIds(
    List<int> ids,
    NovelSearchFilters filters, {
    Map<int, NovelEntity>? incomingNovels,
  }) {
    final aiOnly = filters.aiFilter == SearchAiFilter.only;
    final min = filters.bookmarkMin;
    final max = filters.bookmarkMax;
    if (!aiOnly && min == null && max == null) return ids;
    final store = ref.read(novelStoreProvider.notifier);
    return [
      for (final id in ids)
        if (_passesNovelPredicates(
          incomingNovels?[id] ?? store.get(id),
          aiOnly: aiOnly,
          min: min,
          max: max,
        ))
          id,
    ];
  }

  bool _passesNovelPredicates(
    NovelEntity? entity, {
    required bool aiOnly,
    required int? min,
    required int? max,
  }) {
    if (entity == null) return true;
    // Pixiv's novel_ai_type shares the illust_ai_type contract: 2 = AI work.
    if (aiOnly && entity.novelAiType != 2) return false;
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
      incomingNovels: {for (final item in page.novels) item.id: item},
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
