import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_store.dart';
import '../network/next_page_parser.dart';
import '../paging/paged_feed_controller.dart';
import 'related_illust_repository.dart';

/// Paginated related-illustrations state, one per source work.
///
/// Uses the same PagedFeedController machinery as the feed pages: the ids
/// live in this controller, the payloads merge into the shared illust store
/// through the generation commit.
class _RelatedIllustController extends PagedFeedController {
  _RelatedIllustController(this.illustId);

  final int illustId;

  @override
  String get feedKey => 'related:$illustId';

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final store = ref.read(illustStoreProvider);
    final bookmarkRevision = store.bookmarkRevisionNow();
    final page = await ref
        .read(relatedIllustRepositoryProvider)
        .fetchPage(
          illustId,
          cursor: context.cursor,
          cancelToken: context.cancelToken,
        );
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
    try {
      NextPageParser.parse(rawCursor);
      return rawCursor;
    } on NextPageParseError {
      return null;
    }
  }
}

final relatedIllustControllerProvider =
    AsyncNotifierProvider.family<_RelatedIllustController, PagedFeedState, int>(
      _RelatedIllustController.new,
    );

/// Overridable in tests; the default wired through the shared client.
