import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_store.dart';
import '../network/next_page_parser.dart';
import '../paging/paged_feed_controller.dart';
import 'recommended_repository.dart';

/// Controller for the Recommended Illust tab.
class RecommendedIllustController extends PagedFeedController {
  @override
  String get feedKey => 'recommended:illust';

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final store = ref.read(illustStoreProvider);
    final bookmarkRevision = store.bookmarkRevisionNow();
    final page = await ref
        .read(recommendedIllustRepositoryProvider)
        .fetchPage(context.cursor, cancelToken: context.cancelToken);
    return FeedPage(
      ids: [for (final illust in page.illusts) illust.id],
      nextCursor: page.nextUrl,
      incomingIllusts: {for (final illust in page.illusts) illust.id: illust},
      commit: (_) => store.mergeAll(
        page.illusts,
        bookmarkSnapshotRevision: bookmarkRevision,
      ),
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

final recommendedIllustControllerProvider =
    AsyncNotifierProvider<RecommendedIllustController, PagedFeedState>(
      RecommendedIllustController.new,
    );
