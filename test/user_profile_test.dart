import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/platform/android_intent_channel.dart';
import 'package:pixiv_func/core/share/share_service.dart';
import 'package:pixiv_func/core/user/follow_actions.dart';
import 'package:pixiv_func/core/user/follow_models.dart';
import 'package:pixiv_func/core/user/follow_repository.dart';
import 'package:pixiv_func/core/user/follow_store.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/core/user/user_repository.dart';
import 'package:pixiv_func/core/user/user_store.dart';
import 'package:pixiv_func/core/profile/profile_models.dart';
import 'package:pixiv_func/features/profile/profile_header_delegate.dart';
import 'package:pixiv_func/features/profile/user_page.dart';
import 'package:pixiv_func/app/widgets/follow_switch_button.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

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
  _FakeUserRepository({
    UserEntity? detail,
    this.works = const [],
    this.bookmarks = const [],
    this.worksFailure,
  }) : detail = detail ?? _user(42);

  final UserEntity detail;
  final List<IllustEntity> works;
  final List<IllustEntity> bookmarks;
  final Object? worksFailure;
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

class _FakeOutboundUrlOpener implements OutboundUrlOpener {
  final requests = <String>[];
  Object? failure;

  @override
  Future<void> openExternal(String url) async {
    requests.add(url);
    final error = failure;
    if (error != null) throw error;
  }
}

class _FakeShareService implements ShareService {
  ShareOutcome outcome = ShareOutcome.openedSheet;
  SharePayload? lastPayload;
  Rect? lastOrigin;

  @override
  Future<ShareOutcome> share(
    SharePayload payload, {
    Rect? sharePositionOrigin,
  }) async {
    lastPayload = payload;
    lastOrigin = sharePositionOrigin;
    return outcome;
  }
}

Future<ProviderContainer> _makeWorld({
  bool twoAccounts = false,
  _FakeFollowRepository? follows,
  UserRepository? users,
  OutboundUrlOpener? outboundUrlOpener,
  ShareService? shareService,
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final credentials = FakeCredentialStore(
    values: const {
      '100': Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
      '200': Credential(accessToken: 'access-2', refreshToken: 'refresh-2'),
    },
  );
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
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
        follows ?? _FakeFollowRepository(),
      ),
      if (outboundUrlOpener != null)
        outboundUrlOpenerProvider.overrideWithValue(outboundUrlOpener),
      if (shareService != null)
        shareServiceProvider.overrideWithValue(shareService),
      if (users != null) userRepositoryProvider.overrideWithValue(users),
    ],
  );
  await container.read(accountStoreProvider.future);
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
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

  testWidgets('follow button exposes its label and toggle state', (
    tester,
  ) async {
    final container = await _makeWorld();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          home: Scaffold(
            body: FollowSwitchButton(userId: 42, userName: 'sample user'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.bySemanticsLabel('关注'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('关注')),
      isSemantics(
        label: '关注',
        isButton: true,
        hasToggledState: true,
        isToggled: false,
        hasTapAction: true,
      ),
    );

    container
        .read(followStoreProvider.notifier)
        .observeRemote(42, followed: true, snapshotRevision: 0);
    await tester.pump();

    expect(find.bySemanticsLabel('已关注'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('已关注')),
      isSemantics(
        label: '已关注',
        isButton: true,
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
      ),
    );
  });

  ReplicaProfileHeaderGeometry geometryAt(
    double progress, {
    double topInset = 0,
  }) => ReplicaProfileHeaderGeometry(
    shrinkOffset: (430 - (56 + topInset)) * progress,
    minExtent: 56 + topInset,
    maxExtent: 430,
  );

  test(
    'the expanded identity has one fixed avatar and a separated exit path',
    () {
      expect(ReplicaProfileHeaderGeometry.expandedAvatarRadius * 2, 104);

      Offset centerAt(double progress) => geometryAt(progress).avatarCenter(
        headerWidth: 400,
        backgroundHeight: 252,
        collapsedLeftInset: 56,
      );

      final expanded = centerAt(0);
      expect(expanded.dx, 200);
      expect(
        expanded.dy + ReplicaProfileHeaderGeometry.expandedAvatarRadius,
        252 + 8,
      );

      var previousY = expanded.dy;
      for (var step = 1; step <= 20; step++) {
        final geometry = geometryAt(step / 20);
        final center = centerAt(step / 20);
        expect(center.dx, 200);
        expect(center.dy, lessThan(previousY));
        expect(geometry.avatarRadius, 52);
        previousY = center.dy;
      }

      final collapsed = geometryAt(1);
      expect(collapsed.isFullyCollapsed, isTrue);
      expect(collapsed.showExpandedIdentity, isFalse);
      expect(collapsed.expandedDetailsOpacity, 0);
    },
  );

  test('expanded details crossfade into the toolbar without a blank stage', () {
    final beforeFade = geometryAt(
      ReplicaProfileHeaderGeometry.expandedDetailsFadeStart,
    );
    final afterExit = geometryAt(
      ReplicaProfileHeaderGeometry.expandedIdentityExitProgress,
    );
    expect(beforeFade.expandedDetailsOpacity, 1);
    expect(afterExit.expandedDetailsOpacity, 0);
    expect(afterExit.collapsedOpacity, greaterThan(0));
    expect(geometryAt(1).collapsedOpacity, 1);
  });

  testWidgets('collapsed chrome stays unmounted through the fade interval', (
    tester,
  ) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Scaffold(
          body: CustomScrollView(
            controller: controller,
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
                  onShare: (_) {},
                  expandedExtent: 320,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 1000)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    controller.jumpTo(210); // 80% through the 264dp collapse range.
    await tester.pump();
    expect(find.byKey(const ValueKey('profile-toolbar-title')), findsNothing);

    controller.jumpTo(263.4);
    await tester.pump();
    expect(find.byKey(const ValueKey('profile-toolbar-title')), findsNothing);

    controller.jumpTo(264);
    await tester.pump();
    expect(find.byKey(const ValueKey('profile-toolbar-title')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  test('the pinned toolbar includes the status-bar inset', () {
    final geometry = geometryAt(0, topInset: 24);
    expect(geometry.minExtent, 80);
    expect(geometry.collapseRange, 350);
  });

  test('the background still fades independently of the identity content', () {
    expect(geometryAt(0.5).backgroundOpacity, 0.5);
    expect(geometryAt(1).backgroundOpacity, 0);
  });

  testWidgets(
    'the avatar and expanded name never overlap, and no avatar enters the toolbar',
    (tester) async {
      final users = [
        _user(42).copyWith(
          profileImageUrl: 'https://i.pximg.net/avatar.png',
          backgroundImageUrl: 'https://i.pximg.net/background.png',
        ),
        _user(42),
      ];
      for (final user in users) {
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),

              home: Scaffold(
                body: CustomScrollView(
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
                        onShare: (_) {},
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 2000)),
                  ],
                ),
              ),
            ),
          );
          await tester.pump();

          for (var step = 0; step <= 10; step++) {
            final avatar = find.byKey(
              const ValueKey('profile-expanded-avatar'),
            );
            final name = find.byKey(const ValueKey('profile-expanded-name'));
            if (avatar.evaluate().isNotEmpty && name.evaluate().isNotEmpty) {
              expect(
                tester.getRect(avatar).overlaps(tester.getRect(name)),
                isFalse,
                reason: 'avatar/name overlap at drag step $step',
              );
            }
            await tester.drag(
              find.byType(CustomScrollView),
              const Offset(0, -40),
            );
            await tester.pump();
          }

          expect(
            find.byKey(const ValueKey('profile-expanded-avatar')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('profile-toolbar-title')),
            findsOneWidget,
          );
        });
      }
    },
  );

  testWidgets('collapsed profile chrome starts below the status-bar inset', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),

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
                  onShare: (_) {},
                  topInset: 24,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 1000)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pump();

    final title = tester.getRect(
      find.byKey(const ValueKey('profile-toolbar-title')),
    );
    expect(title.top, greaterThanOrEqualTo(24));
    expect(find.byKey(const ValueKey('profile-expanded-avatar')), findsNothing);
  });

  testWidgets('collapsed toolbar title never overlaps the action row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),

        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: ReplicaProfileHeaderDelegate(
                  user: UserEntity(
                    id: 42,
                    name: 'a very long display name that will not fit',
                    account: 'sample',
                  ),
                  isMe: true,
                  selectedTabIndex: 0,
                  showRestrictSelector: true,
                  restrict: UserRestrict.public,
                  onRestrictChanged: (_) {},
                  onShare: (_) {},
                  onEditProfile: () {},
                  onOpenBookmarkTags: () {},
                  onDownloadAll: () {},
                  topInset: 24,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 1000)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pump();

    final title = tester.getRect(
      find.byKey(const ValueKey('profile-toolbar-title')),
    );
    for (final button in tester.elementList(find.byType(IconButton))) {
      expect(
        title.overlaps(tester.getRect(find.byWidget(button.widget))),
        isFalse,
        reason: 'toolbar title overlaps ${button.widget}',
      );
    }
  });

  testWidgets(
    'expanded and collapsed header actions use the same action list',
    (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),

          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: ReplicaProfileHeaderDelegate(
                    user: _user(42),
                    isMe: true,
                    selectedTabIndex: 0,
                    showRestrictSelector: true,
                    restrict: UserRestrict.public,
                    onRestrictChanged: (_) {},
                    onShare: (_) {},
                    onEditProfile: () {},
                    onOpenBookmarkTags: () {},
                    onDownloadAll: () {},
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 1000)),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byTooltip('分享用户'), findsOneWidget);
      expect(find.byTooltip('编辑个人资料'), findsOneWidget);
      // The persistent overflow carries the full list in every state.
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('分享用户'), findsOneWidget);
      expect(find.text('编辑个人资料'), findsOneWidget);
      expect(find.text('公开'), findsOneWidget);
      expect(find.text('私密'), findsOneWidget);
      expect(find.text('收藏标签'), findsOneWidget);
      expect(find.text('下载全部作品'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      controller.jumpTo(264);
      await tester.pump();
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('分享用户'), findsOneWidget);
      expect(find.text('编辑个人资料'), findsOneWidget);
      expect(find.text('公开'), findsOneWidget);
      expect(find.text('收藏标签'), findsOneWidget);
      expect(find.text('下载全部作品'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('header back button stays mounted through the pop animation', (
    tester,
  ) async {
    Widget header() => Scaffold(
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
              onShare: (_) {},
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 1000)),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => header())),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);

    // pop() removes the route from history immediately — canPop flips false
    // while the pop animation still runs. The header button must not
    // unmount mid-slide.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);
  });

  testWidgets(
    'back and overflow actions fire through the whole collapse interval',
    (tester) async {
      var shareCount = 0;
      final controller = ScrollController();
      Widget header() => Scaffold(
        body: CustomScrollView(
          controller: controller,
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
                onShare: (_) => shareCount++,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 1000)),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => header())),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // expandedExtent 320 - minExtent 56 = 264dp collapse range.
      for (final progress in [0.60, 0.80, 0.95]) {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        controller.jumpTo(264 * progress);
        await tester.pump();

        // The overflow fires even inside the fade hand-off: the expanded
        // row used to be IgnorePointer'd from 0.55 and unmounted at 0.78,
        // while the collapsed toolbar only mounted at the very end.
        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        await tester.tap(find.text('分享用户'));
        await tester.pumpAndSettle();
        expect(shareCount, 1, reason: 'progress $progress');
        shareCount = 0;

        // Back actually pops the pushed route.
        await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
        await tester.pumpAndSettle();
        expect(find.text('open'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'UserPage keeps work types visible and re-tapping never toggles them',
    (tester) async {
      final repository = _FakeUserRepository();
      final container = await _makeWorld(users: repository);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),

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
      expect(find.widgetWithText(ChoiceChip, '插画'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '漫画'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '小说'), findsOneWidget);

      await tester.tap(find.text('作品'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, '插画'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '漫画'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '小说'), findsOneWidget);
      expect(find.byType(EasyRefresh), findsOneWidget);
      expect(find.byType(HeaderLocator), findsOneWidget);

      // Re-tapping a non-work tab must never open the work-type selector.
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, '插画'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, '漫画'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, '小说'), findsNothing);
    },
  );

  testWidgets(
    'profile stats navigate to their sections and keep myPixiv read-only',
    (tester) async {
      final repository = _FakeUserRepository(
        detail: _user(42).copyWith(
          totalFollowUsers: 11,
          totalMyPixivUsers: 12,
          totalIllusts: 13,
          totalManga: 14,
          totalNovels: 15,
          totalIllustSeries: 3,
          totalNovelSeries: 4,
        ),
      );
      final container = await _makeWorld(users: repository);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final seriesStat = find.byKey(
        const ValueKey('profile-stat-series-header'),
      );
      // The series stat counts illust series only: that is what the work
      // tab's series section can display (novel series has no section).
      expect(
        tester.getSemantics(seriesStat),
        isSemantics(label: '系列, 3', isButton: true, hasTapAction: true),
      );
      final myPixivStat = find.byKey(
        const ValueKey('profile-stat-myPixiv-header'),
      );
      expect(
        tester.getSemantics(myPixivStat),
        isSemantics(isButton: false, hasTapAction: false),
      );

      final mangaStat = find.byKey(const ValueKey('profile-stat-manga-header'));
      await tester.ensureVisible(mangaStat);
      await tester.tap(mangaStat);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '漫画'))
            .selected,
        isTrue,
      );
      expect(repository.requests, contains('works:42:manga:first'));
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);

      await tester.tap(
        find.descendant(of: find.byType(TabBar), matching: find.text('关于')),
      );
      await tester.pumpAndSettle();
      final aboutSeriesStat = find.byKey(
        const ValueKey('profile-stat-series-about'),
      );
      await tester.ensureVisible(aboutSeriesStat);
      await tester.tap(aboutSeriesStat);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '系列'))
            .selected,
        isTrue,
      );
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);

      await tester.tap(
        find.descendant(of: find.byType(TabBar), matching: find.text('关于')),
      );
      await tester.pumpAndSettle();
      final aboutFollowingStat = find.byKey(
        const ValueKey('profile-stat-following-about'),
      );
      await tester.ensureVisible(aboutFollowingStat);
      await tester.tap(aboutFollowingStat);
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 2);
      expect(repository.requests, contains('relation:42:following'));

      await tester.tap(
        find.descendant(of: find.byType(TabBar), matching: find.text('关于')),
      );
      await tester.pumpAndSettle();
      final aboutMangaStat = find.byKey(
        const ValueKey('profile-stat-manga-about'),
      );
      await tester.ensureVisible(aboutMangaStat);
      await tester.tap(aboutMangaStat);
      await tester.pumpAndSettle();
      expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '漫画'))
            .selected,
        isTrue,
      );
    },
  );

  testWidgets(
    'same work tab tap returns both profile scroll positions to top',
    (tester) async {
      final repository = _FakeUserRepository(
        works: List.generate(36, (index) => _illust(index + 1)),
      );
      final container = await _makeWorld(users: repository);
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),
              home: const UserPage(userId: 42),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final outerScrollable = find
            .descendant(
              of: find.byKey(const ValueKey('profile-nested-scroll')),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              ),
            )
            .first;
        final innerScrollable = find
            .descendant(
              of: find.byKey(
                const PageStorageKey(
                  ProfileFeedKey(
                    userId: 42,
                    kind: ProfileFeedKind.work,
                    workType: UserWorkType.illust,
                  ),
                ),
              ),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              ),
            )
            .first;
        final outer = tester.state<ScrollableState>(outerScrollable).position;
        final inner = tester.state<ScrollableState>(innerScrollable).position;
        expect(outer.maxScrollExtent, greaterThan(0));
        expect(inner.maxScrollExtent, greaterThan(0));

        outer.jumpTo(80);
        inner.jumpTo(120);
        await tester.pump();
        expect(outer.pixels, greaterThan(0));
        expect(inner.pixels, greaterThan(0));

        await tester.tap(find.text('作品').first);
        await tester.pumpAndSettle();
        expect(outer.pixels, 0);
        expect(inner.pixels, 0);

        outer.jumpTo(80);
        inner.jumpTo(120);
        await tester.pump();
        await tester.tap(find.widgetWithText(ChoiceChip, '插画'));
        await tester.pumpAndSettle();
        expect(outer.pixels, 0);
        expect(inner.pixels, 0);
      });
    },
  );

  testWidgets(
    're-tap scrolls only the active tab; keep-alive siblings keep their '
    'offset',
    (tester) async {
      final repository = _FakeUserRepository(
        works: List.generate(36, (index) => _illust(index + 1)),
        bookmarks: List.generate(36, (index) => _illust(100 + index)),
      );
      final container = await _makeWorld(users: repository);
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),
              home: const UserPage(userId: 42),
            ),
          ),
        );
        await tester.pumpAndSettle();

        ScrollPosition innerOf(ProfileFeedKey key) {
          final scrollable = find
              .descendant(
                of: find.byKey(PageStorageKey(key)),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                ),
              )
              .first;
          return tester.state<ScrollableState>(scrollable).position;
        }

        const workKey = ProfileFeedKey(
          userId: 42,
          kind: ProfileFeedKind.work,
          workType: UserWorkType.illust,
        );
        const bookmarkKey = ProfileFeedKey(
          userId: 42,
          kind: ProfileFeedKind.bookmarks,
          restrict: UserRestrict.public,
        );
        final workPosition = innerOf(workKey);
        expect(workPosition.maxScrollExtent, greaterThan(0));

        // Scroll tab A (作品), then switch to tab B (收藏) — the TabBarView
        // builds a page on first visit, so B's position only exists after
        // the switch — and scroll it.
        workPosition.jumpTo(150);
        await tester.pump();
        await tester.tap(
          find.descendant(of: find.byType(TabBar), matching: find.text('收藏')),
        );
        await tester.pumpAndSettle();
        final bookmarkPosition = innerOf(bookmarkKey);
        expect(bookmarkPosition.maxScrollExtent, greaterThan(0));
        bookmarkPosition.jumpTo(140);
        await tester.pump();
        expect(bookmarkPosition.pixels, 140);
        // NestedScrollView semantics: inner positions are coordinated —
        // user-scroll deltas and position jumps broadcast to every
        // attached keep-alive tab, so A follows B's offset once both are
        // mounted. What must NOT happen is a re-tap rewinding A *again*:
        // the old controller-level animateTo zeroed every position.
        expect(workPosition.pixels, 140);

        await tester.tap(
          find.descendant(of: find.byType(TabBar), matching: find.text('收藏')),
        );
        await tester.pumpAndSettle();
        expect(bookmarkPosition.pixels, 0);
        expect(workPosition.pixels, 140);
      });
    },
  );

  testWidgets('profile social links open, report failures, and copy', (
    tester,
  ) async {
    final opener = _FakeOutboundUrlOpener();
    final clipboardWrites = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardWrites.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final user = _user(42).copyWith(
      webpage: 'https://example.test/portfolio',
      twitterUrl: 'https://social.test/sample',
      pawooUrl: 'https://pawoo.test/sample',
    );
    final container = await _makeWorld(
      users: _FakeUserRepository(detail: user),
      outboundUrlOpener: opener,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: const UserPage(userId: 42),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(TabBar), matching: find.text('关于')),
    );
    await tester.pumpAndSettle();

    final openWebsite = find.byKey(const ValueKey('profile-link-open-website'));
    await tester.ensureVisible(openWebsite);
    await tester.tap(openWebsite);
    await tester.pumpAndSettle();
    expect(opener.requests, contains('https://example.test/portfolio'));

    opener.failure = StateError('no activity');
    final openTwitter = find.byKey(const ValueKey('profile-link-open-twitter'));
    await tester.ensureVisible(openTwitter);
    await tester.tap(openTwitter);
    await tester.pumpAndSettle();
    expect(find.textContaining('无法打开链接'), findsOneWidget);

    final copyPawoo = find.byKey(const ValueKey('profile-link-copy-pawoo'));
    await tester.ensureVisible(copyPawoo);
    await tester.tap(copyPawoo);
    await tester.pumpAndSettle();
    expect(clipboardWrites, contains('https://pawoo.test/sample'));
  });

  testWidgets(
    'collapsed profile follow menu tracks state and opens shared sheet',
    (tester) async {
      final repository = _FakeFollowRepository();
      final container = await _makeWorld(
        follows: repository,
        users: _FakeUserRepository(),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final outerScrollable = find
          .descendant(
            of: find.byKey(const ValueKey('profile-nested-scroll')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first;
      final outer = tester.state<ScrollableState>(outerScrollable).position;
      outer.jumpTo(outer.maxScrollExtent);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('关注'), findsWidgets);
      expect(find.text('私密关注'), findsOneWidget);

      await tester.tap(find.text('私密关注'));
      await tester.pumpAndSettle();
      expect(find.text('关注用户'), findsOneWidget);
      expect(find.byType(SegmentedButton<FollowRestrict>), findsOneWidget);
      await tester.tap(find.text('私密').last);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(repository.requests, contains('add:42:private'));

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('取消关注'), findsOneWidget);
      expect(find.text('私密关注'), findsNothing);
    },
  );

  testWidgets('profile share calls the share service and exposes copy link', (
    tester,
  ) async {
    final share = _FakeShareService()..outcome = ShareOutcome.copiedToClipboard;
    final clipboardWrites = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardWrites.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final container = await _makeWorld(
      users: _FakeUserRepository(),
      shareService: share,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: const UserPage(userId: 42),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final shareButton = find.byTooltip('分享用户');
    final buttonRect = tester.getRect(shareButton);
    await tester.tap(shareButton);
    await tester.pumpAndSettle();
    expect(share.lastPayload?.text, contains('https://www.pixiv.net/users/42'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(share.lastOrigin, isNotNull);
    expect(share.lastOrigin!.width, lessThan(100));
    expect(share.lastOrigin!.height, lessThan(100));
    expect(share.lastOrigin!.center.dx, closeTo(buttonRect.center.dx, 10));
    expect(share.lastOrigin!.center.dy, closeTo(buttonRect.center.dy, 10));
    expect(find.text('链接已复制'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('复制链接'), findsOneWidget);
    await tester.tap(find.text('复制链接'));
    await tester.pumpAndSettle();
    expect(
      clipboardWrites,
      contains(
        'sample user | sample user #Pixiv https://www.pixiv.net/users/42',
      ),
    );
    expect(find.byType(AlertDialog), findsNothing);
  });

  group('profile tab label slots', () {
    const baseSize = 14.0;
    const scaleFloor = 0.55;

    Future<void> pumpTabs(
      WidgetTester tester, {
      required Locale locale,
      required bool isMe,
      double width = 390,
    }) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TabController(length: isMe ? 5 : 4, vsync: tester);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: ReplicaProfileTabsDelegate(
                    controller: controller,
                    isMe: isMe,
                    section: ProfileWorkSection.illust,
                    onTabTap: (_) {},
                    onSectionChanged: (_) {},
                  ),
                ),
                const SliverFillRemaining(),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Finder fittedBoxes() => find.descendant(
      of: find.byType(TabBar),
      matching: find.byType(FittedBox),
    );

    testWidgets('fitting labels keep equal-width slots at natural size', (
      tester,
    ) async {
      // zh 5-tab isMe: the widest label (3 glyphs ~ 42px) fits the 62px
      // slot — the five-slot mirror stays, labels at full size.
      await pumpTabs(tester, locale: const Locale('zh', 'CN'), isMe: true);
      final bar = tester.widget<TabBar>(find.byType(TabBar));
      expect(bar.isScrollable, isFalse);
      expect(bar.labelStyle!.fontSize, baseSize);
      // The unbounded scaler that used to crush labels is gone entirely.
      expect(fittedBoxes(), findsNothing);
    });

    testWidgets('long labels scale down but never below the floor', (
      tester,
    ) async {
      // en 4-tab: "Bookmarked" ~ 140px in an 81.5px slot -> scale ~ 0.58,
      // inside the bounded range — equal slots stay, font >= floor.
      await pumpTabs(tester, locale: const Locale('en'), isMe: false);
      final bar = tester.widget<TabBar>(find.byType(TabBar));
      expect(bar.isScrollable, isFalse);
      expect(bar.labelStyle!.fontSize, lessThan(baseSize));
      expect(
        bar.labelStyle!.fontSize,
        greaterThanOrEqualTo(baseSize * scaleFloor),
      );
      expect(fittedBoxes(), findsNothing);
    });

    testWidgets('narrow surface + long translation + five tabs scroll instead '
        'of shrinking', (tester) async {
      // ru 5-tab isMe @390: "Подписчики" ~ 140px vs a 62px slot — even
      // the 0.55 floor cannot hold it, so the slot hands over to
      // horizontal scrolling (discovery-page parity) with labels back
      // at full size.
      await pumpTabs(tester, locale: const Locale('ru'), isMe: true);
      final bar = tester.widget<TabBar>(find.byType(TabBar));
      expect(bar.isScrollable, isTrue);
      expect(
        bar.labelStyle!.fontSize,
        greaterThanOrEqualTo(baseSize * scaleFloor),
      );
      expect(fittedBoxes(), findsNothing);
    });
  });

  testWidgets(
    'header tabs and actions stay mounted while the work feed fails',
    (tester) async {
      final repository = _FakeUserRepository(
        worksFailure: ApiNetworkError(StateError('offline')),
      );
      final container = await _makeWorld(users: repository);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The work feed's first page request failed, but the query context —
      // tabs, section chips, and the header action row — stays mounted
      // (parent §6 gate: chrome survives loading/error/empty).
      expect(repository.requests, contains('works:42:illust:first'));
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '插画'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '漫画'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '小说'), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-stat-following-header')),
        findsOneWidget,
      );
    },
  );

  testWidgets('tab labels stay on one line at 1.3x text scale', (tester) async {
    final controller = TabController(length: 4, vsync: tester);
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Scaffold(
            body: NestedScrollView(
              headerSliverBuilder: (_, _) => [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: ReplicaProfileTabsDelegate(
                    controller: controller,
                    isMe: false,
                    section: ProfileWorkSection.illust,
                    onTabTap: (_) {},
                    onSectionChanged: (_) {},
                  ),
                ),
              ],
              body: const SizedBox(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Bounded scaling or scroll handover (B4 slot contract): nothing
    // overflows and no label wraps to a second line even at 1.3x
    // (parent §6 / D10).
    expect(tester.takeException(), isNull);
    final tabBar = find.byType(TabBar);
    expect(tabBar, findsOneWidget);
    for (final label in ['作品', '收藏', '关注', '关于']) {
      final text = tester.widget<Text>(
        find.descendant(of: tabBar, matching: find.text(label)),
      );
      // The scrollable path leaves maxLines unset — null and 1 both
      // render single-line.
      expect(text.maxLines ?? 1, 1);
    }
  });
}

UserEntity _user(int id) =>
    UserEntity(id: id, name: 'sample user', account: 'sample');

IllustEntity _illust(int id) => IllustEntity(
  id: id,
  title: 'work $id',
  type: IllustType.illust,
  imageUrls: const IllustImageUrls(
    squareMedium: 'https://i.pximg.net/square.png',
    medium: 'https://i.pximg.net/medium.png',
    large: 'https://i.pximg.net/large.png',
  ),
  caption: '',
  user: const IllustUser(
    id: 42,
    name: 'sample user',
    account: 'sample',
    profileImageUrl: null,
  ),
  tags: const [],
  pageCount: 1,
  width: 300,
  height: 400,
  xRestrict: 0,
  aiType: 0,
  isBookmarked: false,
  totalView: 1,
  totalBookmarks: 1,
);

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
