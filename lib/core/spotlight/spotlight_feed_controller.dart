import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../paging/paged_feed_controller.dart';
import 'spotlight_models.dart';
import 'spotlight_repository.dart';
import 'spotlight_store.dart';

/// Paginated pixivision spotlight article list, one feed per category.
/// IDs live here; entries commit into the SpotlightArticleStore inside the
/// commit gate so a stale/cancelled page writes nothing.
class _SpotlightFeedController extends PagedFeedController {
  _SpotlightFeedController(this.category);

  final SpotlightCategory category;

  @override
  String get feedKey => 'spotlight:${category.name}';

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final page = await ref
        .read(spotlightRepositoryProvider)
        .fetchArticles(
          category: category,
          cursor: context.cursor,
          cancelToken: context.cancelToken,
        );
    return FeedPage(
      ids: [for (final article in page.articles) article.id],
      nextCursor: page.nextUrl,
      commit: (_) => ref
          .read(spotlightArticleStoreProvider.notifier)
          .mergeAll(page.articles),
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    return ref
            .read(spotlightRepositoryProvider)
            .validateArticlesCursor(category, cursor: rawCursor)
        ? rawCursor
        : null;
  }
}

final spotlightFeedProvider =
    AsyncNotifierProvider.family<
      _SpotlightFeedController,
      PagedFeedState,
      SpotlightCategory
    >(_SpotlightFeedController.new);
