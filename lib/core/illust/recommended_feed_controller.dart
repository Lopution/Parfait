import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_store.dart';
import '../network/next_page_parser.dart';
import '../novel/novel_repository.dart';
import '../novel/novel_store.dart';
import '../paging/paged_feed_controller.dart';
import '../user/user_repository.dart';
import '../user/user_store.dart';
import 'recommended_repository.dart';

/// Recommended feed keyed by content type. Each key owns an independent
/// cursor/error/commit lifecycle, matching beta56's home tabs.
typedef RecommendedFeedKey = ({RecommendedContentType type});

/// One lazily-paged Recommended scope/type combination (illust / manga /
/// novel / user).
class RecommendedFeedController extends PagedFeedController {
  RecommendedFeedController(this.key);

  final RecommendedFeedKey key;

  @override
  String get feedKey => 'recommended:${key.type.name}';

  /// C9: discovery content only. Illusts and manga are filtered; novels and
  /// user recommendations have no local-block semantics and stay unfiltered.
  @override
  bool get localFilterEnabled =>
      key.type == RecommendedContentType.illust ||
      key.type == RecommendedContentType.manga;

  @override
  int get filterMinVisible => 24;

  @override
  int get filterMaxRefillPages => 3;

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    switch (key.type) {
      case RecommendedContentType.illust:
      case RecommendedContentType.manga:
        return _fetchIllust(context);
      case RecommendedContentType.novel:
        return _fetchNovel(context);
      case RecommendedContentType.user:
        return _fetchUsers(context);
    }
  }

  Future<FeedPage> _fetchIllust(FeedRequestContext context) async {
    final store = ref.read(illustStoreProvider);
    final bookmarkRevision = store.bookmarkRevisionNow();
    final page = await ref
        .read(recommendedIllustRepositoryProvider)
        .fetchPage(
          context.cursor,
          contentType: recommendedIllustContentType(key.type),
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

  Future<FeedPage> _fetchNovel(FeedRequestContext context) async {
    final store = ref.read(novelStoreProvider.notifier);
    final page = await ref
        .read(novelRepositoryProvider)
        .fetchRecommended(
          cursor: context.cursor,
          cancelToken: context.cancelToken,
        );
    return FeedPage(
      ids: [for (final item in page.novels) item.id],
      nextCursor: page.nextUrl,
      commit: (_) => store.mergeAll(page.novels),
    );
  }

  Future<FeedPage> _fetchUsers(FeedRequestContext context) async {
    final store = ref.read(userStoreProvider.notifier);
    final page = await ref
        .read(userRepositoryProvider)
        .fetchRecommended(
          cursor: context.cursor,
          cancelToken: context.cancelToken,
        );
    return FeedPage(
      ids: [for (final item in page.users) item.id],
      nextCursor: page.nextUrl,
      commit: (_) => store.mergeAll(page.users),
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    // Reject early via the allowlist; store the validated request URI.
    try {
      NextPageParser.parse(rawCursor);
      return rawCursor;
    } on NextPageParseError {
      return null;
    }
  }
}

final recommendedFeedProvider =
    AsyncNotifierProvider.family<
      RecommendedFeedController,
      PagedFeedState,
      RecommendedFeedKey
    >(RecommendedFeedController.new);
