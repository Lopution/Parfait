import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../entity/comment_entity.dart';
import '../entity/illust_store.dart';
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
    final closed = page.commentsClosed;
    if (closed != null) {
      ref.read(commentsClosedProvider.notifier).record(query.workKey, closed);
    }
    // Closed, the one comment is pixiv's notice: kept out of the store and
    // the feed, the pages show that comments are off instead.
    final comments = closed == true ? const <CommentEntity>[] : page.comments;
    ref.read(commentStoreProvider.notifier).mergePage(query, comments);
    final total = page.totalComments;
    if (!query.isReplies && total != null) {
      ref.read(commentTotalsProvider.notifier).record(query.workKey, total);
    }
    return FeedPage(
      ids: [for (final comment in comments) comment.id],
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

final commentFeedProvider = AsyncNotifierProvider.autoDispose
    .family<_CommentFeedController, PagedFeedState, CommentFeedQuery>(
      _CommentFeedController.new,
    );

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

  /// One comment more on [workKey]'s work, sent from this app, counted
  /// from the comments call's total, else [known] (the work's detail).
  /// An unknown total stays unknown: the next comments call brings it.
  void added(String workKey, {int? known}) {
    final total = state[workKey] ?? known;
    if (total != null) state = {...state, workKey: total + 1};
  }
}

/// Whether each work's author turned comments off, as its comments
/// response last said, by [CommentFeedQuery.workKey]. The work's detail
/// payload says it too (`IllustEntity.commentsClosed`); either is enough.
final commentsClosedProvider =
    NotifierProvider<_CommentsClosed, Map<String, bool>>(_CommentsClosed.new);

class _CommentsClosed extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return const {};
  }

  void record(String workKey, bool closed) {
    if (state[workKey] == closed) return;
    state = {...state, workKey: closed};
  }
}

/// Whether the comments on [query]'s work are known to be off: [said] (the
/// [commentsClosedProvider] map) or, for an illustration, its detail
/// payload in [store] says so. Unknown counts as open.
bool commentsClosedFor(
  Map<String, bool> said,
  IllustStore store,
  CommentFeedQuery query,
) =>
    said[query.workKey] == true ||
    (query.kind == CommentWorkKind.illust &&
        store.get(query.workId)?.commentsClosed == true);
