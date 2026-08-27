import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/account_store.dart';
import '../../core/entity/illust_store.dart';
import '../../core/network/api_error.dart';
import '../../core/paging/paged_feed_controller.dart';
import '../../core/user/user_repository.dart';
import '../../core/user/user_store.dart';
import 'profile_models.dart';

/// Paged illustration/manga work feeds. The feed owns only IDs; payloads live
/// in the shared IllustStore.
class ProfileIllustFeedController extends PagedFeedController {
  ProfileIllustFeedController(this.key);

  final ProfileFeedKey key;

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPage(
    String? cursor,
  ) async {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
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
            cursor: cursor,
          )
        : await repository.fetchBookmarks(
            key.userId,
            restrict: key.restrict,
            cursor: cursor,
          );
    store.mergeAll(page.illusts, bookmarkSnapshotRevision: bookmarkRevision);
    return (
      ids: [for (final item in page.illusts) item.id],
      nextCursor: page.nextUrl,
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
class ProfileUserFeedController extends PagedFeedController {
  ProfileUserFeedController(this.key);

  final ProfileFeedKey key;

  UserRelation get _relation => switch (key.kind) {
    ProfileFeedKind.following => UserRelation.following,
    ProfileFeedKind.fans => UserRelation.fans,
    ProfileFeedKind.myPixiv => UserRelation.myPixiv,
    _ => throw StateError('not a user relation feed: $key'),
  };

  @override
  Future<({List<int> ids, String? nextCursor})> fetchPage(
    String? cursor,
  ) async {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    final repository = ref.read(userRepositoryProvider);
    final store = ref.read(userStoreProvider.notifier);
    final followRevision = store.followRevisionNow();
    final page = await repository.fetchRelation(
      key.userId,
      relation: _relation,
      restrict: key.restrict,
      cursor: cursor,
    );
    store.mergeAll(page.users, followSnapshotRevision: followRevision);
    return (
      ids: [for (final user in page.users) user.id],
      nextCursor: page.nextUrl,
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
      ProfileIllustFeedController,
      PagedFeedState,
      ProfileFeedKey
    >(ProfileIllustFeedController.new);

final profileUserFeedProvider =
    AsyncNotifierProvider.family<
      ProfileUserFeedController,
      PagedFeedState,
      ProfileFeedKey
    >(ProfileUserFeedController.new);
