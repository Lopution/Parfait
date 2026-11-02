import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../paging/paged_feed_controller.dart';
import '../profile/profile_models.dart';
import 'novel_entity.dart';
import 'novel_snapshot_codec.dart';
import 'novel_repository.dart';
import 'novel_store.dart';

/// User work feed for Novel previews. Only IDs live in feed state; cards and
/// the reader observe [novelStoreProvider].
class _UserNovelFeedController extends PagedFeedController {
  _UserNovelFeedController(this.userId);

  final int userId;

  @override
  String get feedKey => 'profile:novel:$userId';

  @override
  FeedSnapshotCodec? get snapshotCodec => const NovelSnapshotCodec();

  /// C9: an author's works are discovery content, as for illusts.
  @override
  bool get localFilterEnabled => true;

  @override
  bool get novelIds => true;

  @override
  int get filterMinVisible => 24;

  @override
  int get filterMaxRefillPages => 3;

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    final page = await ref
        .read(novelRepositoryProvider)
        .fetchUserNovels(
          userId,
          cursor: context.cursor,
          cancelToken: context.cancelToken,
        );
    final store = ref.read(novelStoreProvider.notifier);
    return FeedPage(
      ids: [for (final novel in page.novels) novel.id],
      nextCursor: page.nextUrl,
      incomingNovels: {for (final novel in page.novels) novel.id: novel},
      commit: (_) => store.mergeAll(page.novels),
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    return ref
            .read(novelRepositoryProvider)
            .validateUserNovelsCursor(userId, cursor: rawCursor)
        ? rawCursor
        : null;
  }
}

final userNovelFeedProvider = AsyncNotifierProvider.autoDispose
    .family<_UserNovelFeedController, PagedFeedState, int>(
      _UserNovelFeedController.new,
    );

/// A user's novel bookmarks: [ProfileFeedKey.kind] bookmarks with the novel
/// work type, of its restrict and tag.
class _UserNovelBookmarksFeedController extends PagedFeedController {
  _UserNovelBookmarksFeedController(this.key);

  final ProfileFeedKey key;

  @override
  String get feedKey => 'profile:novel:$key';

  @override
  FeedSnapshotCodec? get snapshotCodec => const NovelSnapshotCodec();

  /// C9: bookmarks are the user's own collection, as for illusts.
  @override
  bool get localFilterEnabled => false;

  @override
  bool get novelIds => true;

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    final page = await ref
        .read(novelRepositoryProvider)
        .fetchUserBookmarks(
          key.userId,
          restrict: key.restrict,
          tag: key.bookmarkTag,
          cursor: context.cursor,
          cancelToken: context.cancelToken,
        );
    final store = ref.read(novelStoreProvider.notifier);
    return FeedPage(
      ids: [for (final novel in page.novels) novel.id],
      nextCursor: page.nextUrl,
      incomingNovels: {for (final novel in page.novels) novel.id: novel},
      commit: (_) => store.mergeAll(page.novels),
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    return ref
            .read(novelRepositoryProvider)
            .validateUserBookmarksCursor(
              key.userId,
              restrict: key.restrict,
              tag: key.bookmarkTag,
              cursor: rawCursor,
            )
        ? rawCursor
        : null;
  }
}

final userNovelBookmarksFeedProvider = AsyncNotifierProvider.autoDispose
    .family<_UserNovelBookmarksFeedController, PagedFeedState, ProfileFeedKey>(
      _UserNovelBookmarksFeedController.new,
    );

/// The account's bookmarked novels (Pixiv's markers). Each novel's
/// bookmark lands in [novelStoreProvider] (its [NovelEntity.markerPage]),
/// and its listed page in [markedNovelPagesProvider], which keeps it after
/// the bookmark is removed so the list can put it back.
class _MarkedNovelsFeedController extends PagedFeedController {
  @override
  String get feedKey => 'novel:markers';

  /// A short list of the account's own: no snapshot to restore from.
  @override
  FeedSnapshotCodec? get snapshotCodec => null;

  /// C9: bookmarks are the user's own collection.
  @override
  bool get localFilterEnabled => false;

  @override
  bool get novelIds => true;

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    final page = await ref
        .read(novelRepositoryProvider)
        .fetchMarkedNovels(
          cursor: context.cursor,
          cancelToken: context.cancelToken,
        );
    final novels = [for (final entry in page.entries) entry.novel];
    return FeedPage(
      ids: [for (final novel in novels) novel.id],
      nextCursor: page.nextUrl,
      incomingNovels: {for (final novel in novels) novel.id: novel},
      commit: (_) {
        final store = ref.read(novelStoreProvider.notifier)..mergeAll(novels);
        for (final entry in page.entries) {
          store.updateMarker(entry.novel.id, entry.page);
        }
        ref.read(markedNovelPagesProvider.notifier).add({
          for (final entry in page.entries) entry.novel.id: entry.page,
        });
      },
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    return ref
            .read(novelRepositoryProvider)
            .validateMarkedNovelsCursor(cursor: rawCursor)
        ? rawCursor
        : null;
  }
}

final markedNovelsFeedProvider =
    AsyncNotifierProvider.autoDispose<
      _MarkedNovelsFeedController,
      PagedFeedState
    >(_MarkedNovelsFeedController.new);

/// The Pixiv page each novel of the bookmark list was listed at, for the
/// current account.
class _MarkedNovelPages extends Notifier<Map<int, int>> {
  @override
  Map<int, int> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return const {};
  }

  void add(Map<int, int> pages) => state = {...state, ...pages};
}

final markedNovelPagesProvider =
    NotifierProvider<_MarkedNovelPages, Map<int, int>>(_MarkedNovelPages.new);

/// A novel series' novels, in series order. Like the manga series, it is
/// not filtered: its numbering is the series'. Ids include restricted
/// entries, which have no novel in the store; their rows and each entry's
/// order come from [novelSeriesInfoProvider], which the commit fills.
class _NovelSeriesFeedController extends PagedFeedController {
  _NovelSeriesFeedController(this.seriesId);

  final int seriesId;

  @override
  String get feedKey => 'novel:series:$seriesId';

  /// Opened on purpose from a name or the watchlist: no snapshot.
  @override
  FeedSnapshotCodec? get snapshotCodec => null;

  @override
  bool get novelIds => true;

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    final page = await ref
        .read(novelRepositoryProvider)
        .fetchSeries(
          seriesId,
          cursor: context.cursor,
          cancelToken: context.cancelToken,
        );
    final novels = [for (final entry in page.entries) ?entry.novel];
    return FeedPage(
      ids: [for (final entry in page.entries) entry.id],
      nextCursor: page.nextUrl,
      incomingNovels: {for (final novel in novels) novel.id: novel},
      commit: (_) {
        ref.read(novelStoreProvider.notifier).mergeAll(novels);
        ref.read(novelSeriesInfoProvider(seriesId).notifier).add(page);
      },
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    return ref
            .read(novelRepositoryProvider)
            .validateSeriesCursor(seriesId, cursor: rawCursor)
        ? rawCursor
        : null;
  }
}

final novelSeriesFeedProvider = AsyncNotifierProvider.autoDispose
    .family<_NovelSeriesFeedController, PagedFeedState, int>(
      _NovelSeriesFeedController.new,
    );

/// What a novel series page shows beside its novels: the page that
/// carried the series' facts, and every loaded entry by id.
class NovelSeriesInfo {
  const NovelSeriesInfo({this.header, this.entries = const {}});

  final NovelSeriesPage? header;
  final Map<int, NovelSeriesEntry> entries;
}

class _NovelSeriesInfo extends Notifier<NovelSeriesInfo> {
  _NovelSeriesInfo(this.seriesId);

  final int seriesId;

  @override
  NovelSeriesInfo build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return const NovelSeriesInfo();
  }

  void add(NovelSeriesPage page) => state = NovelSeriesInfo(
    header: page.detail != null ? page : state.header,
    entries: {
      ...state.entries,
      for (final entry in page.entries) entry.id: entry,
    },
  );
}

final novelSeriesInfoProvider = NotifierProvider.autoDispose
    .family<_NovelSeriesInfo, NovelSeriesInfo, int>(_NovelSeriesInfo.new);
