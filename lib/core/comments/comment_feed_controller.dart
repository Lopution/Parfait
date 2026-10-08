import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../paging/paged_feed_controller.dart';
import 'comment_models.dart';
import 'comment_repository.dart';
import 'comment_store.dart';

/// One cancellable paginated state per work/thread and account.
class _CommentFeedController extends PagedFeedController {
  _CommentFeedController(this.query);

  final CommentFeedQuery query;

  @override
  Future<PagedFeedState> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return super.build();
  }

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final repository = ref.read(commentRepositoryProvider);
    final page = query.isReplies
        ? await repository.fetchReplies(
            query.rootCommentId!,
            workId: query.workId,
            kind: query.kind,
            cursor: context.cursor,
            cancelToken: context.cancelToken,
          )
        : await repository.fetchComments(
            query.workId,
            kind: query.kind,
            cursor: context.cursor,
            cancelToken: context.cancelToken,
          );
    ref.read(commentStoreProvider.notifier).mergePage(query, page.comments);
    final total = page.totalComments;
    if (!query.isReplies && total != null) {
      ref.read(commentTotalsProvider.notifier).record(query.workKey, total);
    }
    return FeedPage(
      ids: [for (final comment in page.comments) comment.id],
      nextCursor: page.nextUrl,
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    return ref
            .read(commentRepositoryProvider)
            .validateCursor(query, cursor: rawCursor)
        ? rawCursor
        : null;
  }

  /// Adds a confirmed mutation without touching the active page cursor.
  void prepend(int commentId) {
    final current = state.asData?.value;
    if (current == null || current.ids.contains(commentId)) return;
    state = AsyncData(current.copyWith(ids: [commentId, ...current.ids]));
  }

  /// Removes a confirmed mutation from this visible feed.
  void removeId(int commentId) {
    final current = state.asData?.value;
    if (current == null || !current.ids.contains(commentId)) return;
    state = AsyncData(
      current.copyWith(
        ids: current.ids.where((id) => id != commentId).toList(),
      ),
    );
  }
}

final commentFeedProvider =
    AsyncNotifierProvider.family<
      _CommentFeedController,
      PagedFeedState,
      CommentFeedQuery
    >(_CommentFeedController.new);

/// The comment count each work's comments response last reported, by
/// [CommentFeedQuery.workKey]. The comments call carries it, so the detail
/// page can show the count without asking the detail API.
final commentTotalsProvider =
    NotifierProvider<_CommentTotals, Map<String, int>>(_CommentTotals.new);

class _CommentTotals extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return const {};
  }

  void record(String workKey, int total) {
    if (state[workKey] == total) return;
    state = {...state, workKey: total};
  }
}
