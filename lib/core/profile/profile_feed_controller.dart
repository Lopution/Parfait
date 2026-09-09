import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../entity/illust_store.dart';
import '../network/api_error.dart';

import '../paging/paged_feed_controller.dart';
import '../user/user_repository.dart';
import '../user/user_store.dart';
import 'profile_models.dart';

/// Paged illustration/manga work feeds. The feed owns only IDs; payloads live
/// in the shared IllustStore.
class _ProfileIllustFeedController extends PagedFeedController {
  _ProfileIllustFeedController(this.key);

  final ProfileFeedKey key;

  @override
  String get feedKey => 'profile:illust:$key';

  /// C9: the author's own work list is discovery content; bookmarks,
  /// follow lists and fan lists are the user's own collections and stay
  /// unfiltered (the user chose them).
  @override
  bool get localFilterEnabled =>
      key.kind == ProfileFeedKind.work && key.workType != UserWorkType.novel;

  @override
  int get filterMinVisible => 24;

  @override
  int get filterMaxRefillPages => 3;

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    if (key.workType == UserWorkType.novel) {
      throw const ApiParseError(
        'novel profile feeds are provided by the novel-reader task',
      );
    }
    final repository = ref.read(userRepositoryProvider);
    final store = ref.read(illustStoreProvider);
    final bookmarkRevision = store.bookmarkRevisionNow();
    final page = key.kind == ProfileFeedKind.work
        ? await repository.fetchWorks(
            key.userId,
            type: key.workType,
            cursor: context.cursor,
            cancelToken: context.cancelToken,
          )
        : await repository.fetchBookmarks(
            key.userId,
            restrict: key.restrict,
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

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    final repository = ref.read(userRepositoryProvider);
    final valid = key.kind == ProfileFeedKind.work
        ? repository.validateWorksCursor(
            key.userId,
            type: key.workType,
            cursor: rawCursor,
          )
        : repository.validateBookmarksCursor(
            key.userId,
            restrict: key.restrict,
            cursor: rawCursor,
          );
    return valid ? rawCursor : null;
  }
}

/// Paged relation feeds. The feed owns only user IDs; previews and detail
/// fields are merged into the shared UserStore.
class _ProfileUserFeedController extends PagedFeedController {
  _ProfileUserFeedController(this.key);

  final ProfileFeedKey key;

  @override
  String get feedKey => 'profile:user:$key';

  UserRelation get _relation => switch (key.kind) {
    ProfileFeedKind.following => UserRelation.following,
    ProfileFeedKind.fans => UserRelation.fans,
    ProfileFeedKind.myPixiv => UserRelation.myPixiv,
    _ => throw StateError('not a user relation feed: $key'),
  };

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    final repository = ref.read(userRepositoryProvider);
    final store = ref.read(userStoreProvider.notifier);
    final followRevision = store.followRevisionNow();
    final page = await repository.fetchRelation(
      key.userId,
      relation: _relation,
      restrict: key.restrict,
      cursor: context.cursor,
      cancelToken: context.cancelToken,
    );
    return FeedPage(
      ids: [for (final user in page.users) user.id],
      nextCursor: page.nextUrl,
      commit: (_) =>
          store.mergeAll(page.users, followSnapshotRevision: followRevision),
    );
  }

  @override
  String? validateCursor(String? rawCursor) {
    if (rawCursor == null) return null;
    return ref
            .read(userRepositoryProvider)
            .validateRelationCursor(
              key.userId,
              relation: _relation,
              restrict: key.restrict,
              cursor: rawCursor,
            )
        ? rawCursor
        : null;
  }
}

final profileIllustFeedProvider =
    AsyncNotifierProvider.family<
      _ProfileIllustFeedController,
      PagedFeedState,
      ProfileFeedKey
    >(_ProfileIllustFeedController.new);

final profileUserFeedProvider =
    AsyncNotifierProvider.family<
      _ProfileUserFeedController,
      PagedFeedState,
      ProfileFeedKey
    >(_ProfileUserFeedController.new);
