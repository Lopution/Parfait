import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/illust_store.dart';
import '../network/next_page_parser.dart';
import '../paging/paged_feed_controller.dart';
import 'ranking_repository.dart';

/// One independent cursor/state machine per ranking mode.
class _RankingFeedController extends PagedFeedController {
  _RankingFeedController(this.mode);

  final RankingMode mode;

  @override
  String get feedKey => 'ranking:${mode.apiValue}';

  /// C9: ranking is discovery content.
  @override
  bool get localFilterEnabled => true;

  @override
  int get filterMinVisible => 24;

  @override
  int get filterMaxRefillPages => 3;

  @override
  Future<PagedFeedState> build() {
    // A provider family instance must reset when the current account changes;
    // otherwise a cached mode/cursor from account A can leak into account B.
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return super.build();
  }

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final store = ref.read(illustStoreProvider);
    final bookmarkRevision = store.bookmarkRevisionNow();
    final page = await ref
        .read(rankingRepositoryProvider)
        .fetchPage(mode, context.cursor, cancelToken: context.cancelToken);
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
    if (rawCursor == null || rawCursor.isEmpty) return null;
    try {
      final request = NextPageParser.parse(rawCursor)!;
      RankingRepository.validateModeCursor(request, mode);
      return rawCursor;
    } on NextPageParseError {
      return null;
    }
  }
}

final rankingFeedControllerProvider =
    AsyncNotifierProvider.family<
      _RankingFeedController,
      PagedFeedState,
      RankingMode
    >(_RankingFeedController.new);
