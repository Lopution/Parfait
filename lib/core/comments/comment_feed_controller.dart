import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../network/pixiv_http_client.dart';
import '../paging/paged_feed_controller.dart';
import 'comment_models.dart';
import 'comment_repository.dart';
import 'comment_store.dart';

/// One cancellable paginated state per work/thread and account.
class CommentFeedController extends PagedFeedController {
  CommentFeedController(this.query);

  final CommentFeedQuery query;

  @override
  Future<PagedFeedState> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return super.build();
  }

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPage(String? cursor) =>
      fetchPageCancellable(cursor, CancelToken());

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPageCancellable(
    String? cursor,
    CancelToken cancelToken,
  ) async {
    final repository = ref.read(commentRepositoryProvider);
    final page = query.isReplies
        ? await repository.fetchReplies(
            query.rootCommentId!,
            illustId: query.illustId,
            cursor: cursor,
            cancelToken: cancelToken,
          )
        : await repository.fetchComments(
            query.illustId,
            cursor: cursor,
            cancelToken: cancelToken,
          );
    ref.read(commentStoreProvider.notifier).mergePage(query, page.comments);
    return (
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
      CommentFeedController,
      PagedFeedState,
      CommentFeedQuery
    >(CommentFeedController.new);
