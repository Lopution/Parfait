import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/user/follow_actions.dart';
import 'package:pixiv_func/core/user/follow_models.dart';
import 'package:pixiv_func/core/user/follow_repository.dart';
import 'package:pixiv_func/core/user/follow_store.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/core/user/user_repository.dart';
import 'package:pixiv_func/core/user/user_store.dart';
import 'package:pixiv_func/features/profile/profile_header_delegate.dart';
import 'package:pixiv_func/features/profile/user_page.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _FakeCredentialStore implements CredentialStore {
  final values = <String, Credential>{};

  @override
  Future<Credential?> read(String accountId) async => values[accountId];

  @override
  Future<void> write(String accountId, Credential credential) async =>
      values[accountId] = credential;

  @override
  Future<void> delete(String accountId) async => values.remove(accountId);
}

class _FakeMetadataRepository implements AccountMetadataRepository {
  _FakeMetadataRepository({this.twoAccounts = false});

  final bool twoAccounts;

  @override
  Future<AccountMetadataSnapshot> load() async => AccountMetadataSnapshot(
    accounts: [
      const Account(id: '100', userId: 100, name: 'first'),
      if (twoAccounts) const Account(id: '200', userId: 200, name: 'second'),
    ],
    currentId: '100',
  );

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {}
}

class _FakeFollowRepository implements FollowRepository {
  final requests = <String>[];
  Completer<void>? gate;
  Object? failure;

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
}

class _FakeUserRepository implements UserRepository {
  _FakeUserRepository({UserEntity? detail}) : detail = detail ?? _user(42);

  final UserEntity detail;
  final requests = <String>[];

  @override
  Future<UserEntity> fetchDetail(int userId, {CancelToken? cancelToken}) async {
    requests.add('detail:$userId');
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
    return const UserIllustPage(illusts: [], nextUrl: null);
  }

  @override
  Future<UserIllustPage> fetchBookmarks(
    int userId, {
    required UserRestrict restrict,
    String? cursor,
    CancelToken? cancelToken,
  }) async {
    requests.add('bookmarks:$userId:${restrict.name}');
    return const UserIllustPage(illusts: [], nextUrl: null);
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

Future<ProviderContainer> _makeWorld({
  bool twoAccounts = false,
  _FakeFollowRepository? follows,
  UserRepository? users,
}) async {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  final credentials = _FakeCredentialStore()
    ..values['100'] = const Credential(
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
    )
    ..values['200'] = const Credential(
      accessToken: 'access-2',
      refreshToken: 'refresh-2',
    );
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        _FakeMetadataRepository(twoAccounts: twoAccounts),
      ),
      followRepositoryProvider.overrideWithValue(
        follows ?? _FakeFollowRepository(),
      ),
      if (users != null) userRepositoryProvider.overrideWithValue(users),
    ],
  );
  await container.read(accountStoreProvider.future);
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('detail and preview payloads normalize without losing profile data', () {
    final detail = UserEntity.fromDetailJson(_detailJson());
    final preview = UserEntity.fromPreviewJson({
      'user': {
        'id': 42,
        'name': 'Updated name',
        'account': 'updated',
        'profile_image_urls': {
          'medium': 'https://i.pximg.net/avatar-updated.png',
        },
        'is_followed': true,
      },
      'is_muted': false,
    });
    final merged = detail.merge(preview);

    expect(merged.name, 'Updated name');
    expect(merged.backgroundImageUrl, 'https://i.pximg.net/background.png');
    expect(merged.totalIllusts, 12);
    expect(merged.isFollowed, isTrue);
    expect(merged.hasDetail, isTrue);
  });

  test(
    'follow action exposes pending state and commits through the store',
    () async {
      final gate = Completer<void>();
      final repository = _FakeFollowRepository()..gate = gate;
      final container = await _makeWorld(follows: repository);
      final userStore = container.read(userStoreProvider.notifier);
      userStore.mergeAll([_user(42)]);

      final action = container.read(followActionsProvider).toggle(42);
      await Future<void>.delayed(Duration.zero);
      final pending = container.read(followStoreProvider)[42]!;
      expect(pending.isPending, isTrue);
      expect(pending.followed, isFalse);
      expect(container.read(userStoreProvider)[42]!.isFollowed, isNull);

      gate.complete();
      await action;
      expect(container.read(followStoreProvider)[42]!.followed, isTrue);
      expect(container.read(followStoreProvider)[42]!.isPending, isFalse);
      expect(container.read(userStoreProvider)[42]!.isFollowed, isTrue);
    },
  );

  test(
    'follow failure restores confirmed state and records the error',
    () async {
      final repository = _FakeFollowRepository()
        ..failure = StateError('offline');
      final container = await _makeWorld(follows: repository);
      final userStore = container.read(userStoreProvider.notifier);
      userStore.mergeAll([_user(42)]);

      await container.read(followActionsProvider).toggle(42);
      final entry = container.read(followStoreProvider)[42]!;
      expect(entry.followed, isFalse);
      expect(entry.isPending, isFalse);
      expect(entry.error, isA<StateError>());
    },
  );

  test(
    'follow state and user entities are isolated when account changes',
    () async {
      final container = await _makeWorld(twoAccounts: true);
      final userStore = container.read(userStoreProvider.notifier);
      final follows = container.read(followStoreProvider.notifier);
      userStore.mergeAll([_user(42)]);
      follows.observeRemote(42, followed: true, snapshotRevision: 0);

      await container.read(accountStoreProvider.notifier).switchAccount('200');
      await Future<void>.delayed(Duration.zero);

      expect(container.read(userStoreProvider), isEmpty);
      expect(container.read(followStoreProvider), isEmpty);
    },
  );

  ReplicaProfileHeaderGeometry geometryAt(double progress) =>
      ReplicaProfileHeaderGeometry(
        shrinkOffset: 374 * progress,
        minExtent: 56,
        maxExtent: 430,
      );

  test(
    'header geometry only reports the title at the fully collapsed extent',
    () {
      final geometry = geometryAt(0);
      expect(geometry.isFullyCollapsed, isFalse);
      expect(geometry.avatarRadius, 52);

      final collapsed = geometryAt(1);
      expect(collapsed.isFullyCollapsed, isTrue);
      expect(collapsed.avatarRadius, 20);
    },
  );

  test('D7: the avatar interpolates instead of switching between two sizes', () {
    // 104dp across expanded, inside the 96-112dp the PRD asks for.
    expect(ReplicaProfileHeaderGeometry.expandedAvatarRadius * 2, 104);

    var previous = geometryAt(0).avatarRadius;
    for (var step = 1; step <= 20; step++) {
      final radius = geometryAt(step / 20).avatarRadius;
      expect(
        radius,
        lessThanOrEqualTo(previous),
        reason: 'the radius must shrink monotonically, never jump back',
      );
      // No step may cover more than a small slice of the whole travel; a
      // two-state switch would show up here as one 32px step.
      expect(previous - radius, lessThan(4));
      previous = radius;
    }
    expect(previous, ReplicaProfileHeaderGeometry.collapsedAvatarRadius);
  });

  test('D7: the avatar travels continuously to the collapsed anchor', () {
    Offset centerAt(double progress) => geometryAt(progress).avatarCenter(
      headerWidth: 400,
      backgroundHeight: 252,
      collapsedLeftInset: 56,
    );

    // Expanded: horizontally centred, hanging 24px past the background edge.
    final expanded = centerAt(0);
    expect(expanded.dx, 200);
    expect(
      expanded.dy + ReplicaProfileHeaderGeometry.expandedAvatarRadius,
      252 + 24,
    );

    // Collapsed: toolbar row, immediately right of the leading slot.
    final collapsed = centerAt(1);
    expect(collapsed.dx, 56 + 20);
    expect(collapsed.dy, 28);

    var previous = expanded;
    for (var step = 1; step <= 20; step++) {
      final center = centerAt(step / 20);
      expect((previous - center).distance, lessThan(20));
      previous = center;
    }
    expect(previous, collapsed);
  });

  test('D7: the avatar is parked before the toolbar chrome fades in', () {
    // The collapsed title's 96px inset is sized for the collapsed avatar, so
    // a still-shrinking avatar would sweep across the appearing title. Sample
    // finely: a coarse sweep steps straight over a narrow overlap window.
    const steps = 400;
    for (var step = 0; step <= steps; step++) {
      final progress = step / steps;
      final geometry = geometryAt(progress);
      if (geometry.collapsedOpacity > 0) {
        expect(
          geometry.avatarRadius,
          ReplicaProfileHeaderGeometry.collapsedAvatarRadius,
          reason: 'avatar still moving at progress $progress',
        );
        expect(
          geometry
              .avatarCenter(
                headerWidth: 400,
                backgroundHeight: 252,
                collapsedLeftInset: 56,
              )
              .dx +
              geometry.avatarRadius,
          lessThanOrEqualTo(96),
          reason: 'avatar reaches into the title inset at progress $progress',
        );
      }
    }
    expect(geometryAt(0).collapsedOpacity, 0);
    expect(geometryAt(1).collapsedOpacity, 1);
  });

  test('D7: the avatar does not share the background fade', () {
    // U8: a 144dp placeholder fading out with the background read as a
    // watermark. The avatar layer must have no opacity curve of its own.
    expect(geometryAt(0.5).backgroundOpacity, 0.5);
    expect(geometryAt(1).backgroundOpacity, 0);
  });

  testWidgets(
    'U8: the avatar stays visible and unfaded across the whole transition',
    (tester) async {
      final withAvatar = _user(42).copyWith(
        profileImageUrl: 'https://i.pximg.net/avatar.png',
        backgroundImageUrl: 'https://i.pximg.net/background.png',
      );
      // The second case is the one U8 reported: the default placeholder at
      // 144dp faded out with the background like a watermark.
      for (final user in [withAvatar, _user(42)]) {
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: CustomScrollView(
                  // Distinct keys per case: pumpWidget reuses a structurally
                  // identical tree, and with it the ScrollPosition the
                  // previous case left scrolled to the bottom.
                  key: ValueKey(user.profileImageUrl ?? 'placeholder'),
                  slivers: [
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: ReplicaProfileHeaderDelegate(
                        user: user,
                        isMe: true,
                        selectedTabIndex: 0,
                        showRestrictSelector: false,
                        restrict: UserRestrict.public,
                        onRestrictChanged: (_) {},
                        onShare: () {},
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 2000)),
                  ],
                ),
              ),
            ),
          );
          await tester.pump();

          final sizes = <double>[];
          for (var step = 0; step <= 10; step++) {
            // Exactly one avatar at every scroll offset: the old header
            // swapped between two hardcoded ones at the collapse threshold.
            final avatar = find.byType(CircleAvatar);
            expect(
              avatar,
              findsOneWidget,
              reason: 'no avatar at drag step $step',
            );
            sizes.add(tester.getSize(avatar).width);

            // Nothing between the avatar and the header may fade it. The
            // background does fade; the avatar must not ride that curve.
            for (final opacity in tester.widgetList<Opacity>(
              find.ancestor(of: avatar, matching: find.byType(Opacity)),
            )) {
              expect(opacity.opacity, 1);
            }

            await tester.drag(
              find.byType(CustomScrollView),
              const Offset(0, -40),
            );
            await tester.pump();
          }

          expect(sizes.first, ReplicaProfileHeaderGeometry.expandedAvatarRadius * 2);
          expect(sizes.last, ReplicaProfileHeaderGeometry.collapsedAvatarRadius * 2);
          for (var i = 1; i < sizes.length; i++) {
            expect(
              sizes[i],
              lessThanOrEqualTo(sizes[i - 1]),
              reason: 'avatar grew back between steps: $sizes',
            );
          }
        });
      }
    },
  );

  testWidgets('current profile header has no settings entry', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: ReplicaProfileHeaderDelegate(
                  user: _user(42),
                  isMe: true,
                  selectedTabIndex: 0,
                  showRestrictSelector: false,
                  restrict: UserRestrict.public,
                  onRestrictChanged: (_) {},
                  onShare: () {},
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 1000)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.settings_outlined), findsNothing);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pump();
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
  });

  testWidgets(
    'UserPage renders tabs and re-tapping the current tab opens type selector',
    (tester) async {
      final repository = _FakeUserRepository();
      final container = await _makeWorld(users: repository);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('作品'), findsOneWidget);
      expect(find.text('收藏'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(TabBar), matching: find.text('关注')),
        findsOneWidget,
      );
      expect(find.text('关于'), findsOneWidget);
      expect(find.text('sample user'), findsOneWidget);

      await tester.tap(find.text('作品'));
      await tester.pump();
      expect(find.text('插画'), findsOneWidget);
      expect(find.text('漫画'), findsOneWidget);
      expect(find.text('小说'), findsOneWidget);
    },
  );
}

UserEntity _user(int id) =>
    UserEntity(id: id, name: 'sample user', account: 'sample');

Map<String, dynamic> _detailJson() => {
  'user': {
    'id': 42,
    'name': 'sample user',
    'account': 'sample',
    'profile_image_urls': {'medium': 'https://i.pximg.net/avatar.png'},
    'comment': 'hello',
    'is_followed': false,
  },
  'profile': {
    'background_image_url': 'https://i.pximg.net/background.png',
    'total_follow_users': 4,
    'total_mypixiv_users': 3,
    'total_illusts': 12,
    'total_manga': 2,
    'total_novels': 1,
    'total_illust_bookmarks_public': 5,
    'total_illust_series': 1,
    'total_novel_series': 1,
  },
};
