import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/bookmark/bookmark_repository.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/platform/android_intent_channel.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/share/share_service.dart';
import 'package:parfait/core/user/follow_models.dart';
import 'package:parfait/core/user/follow_repository.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/core/user/user_repository.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'bookmark_world.dart';
import 'fake_account.dart';
import 'memory_feed_snapshot_store.dart';
import 'test_preferences.dart';

class FakeFollowRepository implements FollowRepository {
  final requests = <String>[];
  Completer<void>? gate;
  Object? failure;

  /// What `fetchRestrict` answers; [restrictFailure] makes it throw.
  FollowRestrict? remoteRestrict = FollowRestrict.public;
  Object? restrictFailure;

  @override
  Future<void> add(
    int userId, {
    FollowRestrict restrict = FollowRestrict.public,
    CancelToken? cancelToken,
  }) async {
    requests.add('add:$userId:${restrict.name}');
    final activeGate = gate;
    if (activeGate != null) await activeGate.future;
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<void> delete(int userId, {CancelToken? cancelToken}) async {
    requests.add('delete:$userId');
    final activeGate = gate;
    if (activeGate != null) await activeGate.future;
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<FollowRestrict?> fetchRestrict(
    int userId, {
    CancelToken? cancelToken,
  }) async {
    requests.add('restrict:$userId');
    if (restrictFailure case final error?) throw error;
    return remoteRestrict;
  }
}

class FakeUserRepository implements UserRepository {
  FakeUserRepository({
    UserEntity? detail,
    this.works = const [],
    this.bookmarks = const [],
    this.worksFailure,
    this.detailFailure,
  }) : detail = detail ?? sampleUser(42);

  // Mutable so a refresh scenario can change what fetchDetail returns.
  UserEntity detail;
  final List<IllustEntity> works;
  final List<IllustEntity> bookmarks;
  final Object? worksFailure;
  final Object? detailFailure;

  /// When set, `fetchWorks` waits on it — lets a test observe the feed's
  /// loading state instead of racing past it.
  Completer<void>? worksGate;

  /// Same gate for `fetchDetail` — holds the profile header's first load.
  Completer<void>? detailGate;
  final requests = <String>[];

  @override
  Future<UserEntity> fetchDetail(int userId, {CancelToken? cancelToken}) async {
    requests.add('detail:$userId');
    final gate = detailGate;
    if (gate != null) await gate.future;
    final error = detailFailure;
    if (error != null) throw error;
    return detail.copyWith(id: userId);
  }

  @override
  Future<UserIllustPage> fetchWorks(
    int userId, {
    required UserWorkType type,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add(
      'works:$userId:${type.name}:${cursor == null ? 'first' : 'next'}',
    );
    final gate = worksGate;
    if (gate != null) await gate.future;
    final error = worksFailure;
    if (error != null) throw error;
    return UserIllustPage(
      illusts: type == UserWorkType.illust ? works : const [],
      nextUrl: null,
    );
  }

  @override
  Future<UserIllustPage> fetchBookmarks(
    int userId, {
    required UserRestrict restrict,
    String? tag,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add('bookmarks:$userId:${restrict.name}:${tag ?? ''}');
    return UserIllustPage(illusts: bookmarks, nextUrl: null);
  }

  @override
  bool validateWorksCursor(
    int userId, {
    required UserWorkType type,
    required String cursor,
  }) => false;

  @override
  bool validateBookmarksCursor(
    int userId, {
    required UserRestrict restrict,
    String? tag,
    required String cursor,
  }) => false;

  @override
  Future<UserRelationPage> fetchRelation(
    int userId, {
    required UserRelation relation,
    UserRestrict restrict = UserRestrict.public,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add('relation:$userId:${relation.name}');
    return const UserRelationPage(users: [], nextUrl: null);
  }

  @override
  bool validateRelationCursor(
    int userId, {
    required UserRelation relation,
    required UserRestrict restrict,
    required String cursor,
  }) => false;

  @override
  Future<UserRelationPage> fetchRecommended({
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add('recommended:${cursor == null ? 'first' : 'next'}');
    return const UserRelationPage(users: [], nextUrl: null);
  }

  @override
  bool validateRecommendedCursor({required String cursor}) => false;
}

/// The profile's repositories over in-memory fakes; its controllers and
/// stores run real.
Future<ProviderContainer> makeProfileWorld({
  bool twoAccounts = false,
  FakeFollowRepository? follows,
  UserRepository? users,
  BookmarkRepository? bookmarks,
  OutboundUrlOpener? outboundUrlOpener,
  ShareService? shareService,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  // Per-world snapshot store: sqflite singleInstance caches the default
  // ':memory:' feeds.db by path, so one test's committed snapshot would
  // leak into the next world's cold start. An in-memory store keeps the
  // same read/write contract without touching sqlite inside FakeAsync.
  final feedSnapshots = MemoryFeedSnapshotStore();
  final credentials = FakeCredentialStore(
    values: const {
      '100': Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
      '200': Credential(accessToken: 'access-2', refreshToken: 'refresh-2'),
    },
  );
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      feedSnapshotStoreProvider.overrideWithValue(feedSnapshots),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: [
            const Account(id: '100', userId: 100, name: 'first'),
            if (twoAccounts)
              const Account(id: '200', userId: 200, name: 'second'),
          ],
          currentId: '100',
        ),
      ),
      followRepositoryProvider.overrideWithValue(
        follows ?? FakeFollowRepository(),
      ),
      if (outboundUrlOpener != null)
        outboundUrlOpenerProvider.overrideWithValue(outboundUrlOpener),
      if (shareService != null)
        shareServiceProvider.overrideWithValue(shareService),
      if (users != null) userRepositoryProvider.overrideWithValue(users),
      // Own bookmarks list their tags in the filter bar.
      bookmarkRepositoryProvider.overrideWithValue(
        bookmarks ?? RecordingBookmarkRepository(),
      ),
    ],
  );
  await container.read(accountStoreProvider.future);
  addTearDown(container.dispose);
  return container;
}

UserEntity sampleUser(int id) =>
    UserEntity(id: id, name: 'sample user', account: 'sample');
