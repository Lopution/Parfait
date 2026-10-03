import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/platform/android_intent_channel.dart';
import 'package:parfait/core/share/share_service.dart';
import 'package:parfait/core/user/follow_actions.dart';
import 'package:parfait/core/user/follow_models.dart';
import 'package:parfait/core/user/follow_repository.dart';
import 'package:parfait/core/user/follow_store.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/core/user/user_detail_controller.dart';
import 'package:parfait/core/user/user_repository.dart';
import 'package:parfait/core/user/user_store.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/profile/profile_models.dart';
import 'package:parfait/app/scroll_behavior.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/func_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_menu_button.dart';
import 'package:parfait/app/widgets/app_type_switch.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/skeleton/illust_grid_skeleton.dart';
import 'package:parfait/features/profile/profile_header_delegate.dart';
import 'package:parfait/features/profile/profile_illust_feed.dart';
import 'package:parfait/features/profile/profile_novel_feed.dart';
import 'package:parfait/features/profile/user_page.dart';
import 'package:parfait/features/profile/profile_skeleton.dart';
import 'package:parfait/features/profile/user_series_feed.dart';
import 'package:parfait/app/widgets/follow_switch_button.dart';
import 'package:parfait/app/widgets/image_overlay_button.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/fake_account.dart';
import 'helpers/memory_feed_snapshot_store.dart';
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
    this.detailFailure,
  }) : detail = detail ?? _user(42);

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

/// Mounts the profile header sliver exactly the way `UserPage` does: the
/// expanded extent starts unset, the identity block reports its measured
/// height after the first layout, and the delegate is rebuilt with it.
/// Tests read [collapseRange] for scroll distances instead of hard-coding
/// the old fixed-extent dp values.
class _MeasuredProfileHeader extends StatefulWidget {
  const _MeasuredProfileHeader({required this.delegateFor});

  final ReplicaProfileHeaderDelegate Function(
    double? expandedExtent,
    ValueChanged<double> onMeasured,
  )
  delegateFor;

  @override
  State<_MeasuredProfileHeader> createState() => _MeasuredProfileHeaderState();
}

class _MeasuredProfileHeaderState extends State<_MeasuredProfileHeader> {
  double? _extent;
  ReplicaProfileHeaderDelegate? _delegate;

  double get collapseRange => _delegate!.maxExtent - _delegate!.minExtent;

  @override
  Widget build(BuildContext context) {
    final delegate = widget.delegateFor(_extent, (extent) {
      if (_extent == null || (extent - _extent!).abs() > 0.5) {
        setState(() => _extent = extent);
      }
    });
    _delegate = delegate;
    return SliverPersistentHeader(pinned: true, delegate: delegate);
  }
}

/// Scroll distance that fully collapses the mounted measured header.
double _headerCollapseRange(WidgetTester tester) => tester
    .state<_MeasuredProfileHeaderState>(find.byType(_MeasuredProfileHeader))
    .collapseRange;

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

  test('a page of users lands its follow snapshots as one write', () async {
    final container = await _makeWorld();
    var writes = 0;
    container.listen(followStoreProvider, (_, _) => writes++);
    final users = [
      for (var id = 300; id < 330; id++)
        _user(id).copyWith(isFollowed: id.isEven),
    ];

    container.read(userStoreProvider.notifier).mergeAll(users);
    expect(writes, 1);
    expect(container.read(followStoreProvider)[300]!.followed, isTrue);
    expect(container.read(followStoreProvider)[301]!.followed, isFalse);

    container.read(userStoreProvider.notifier).mergeAll(users);
    expect(writes, 1, reason: 'an unchanged page must not notify');
  });

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
    double shrinkOffset, {
    double minExtent = 56,
    double maxExtent = 430,
  }) => ReplicaProfileHeaderGeometry(
    shrinkOffset: shrinkOffset,
    minExtent: minExtent,
    maxExtent: maxExtent,
  );

  test('the banner keeps a fixed band while the identity scrolls out', () {
    expect(ReplicaProfileHeaderGeometry.bannerBelowToolbar, 80);
    expect(ReplicaProfileHeaderGeometry.avatarRadius, 40);
    expect(ReplicaProfileHeaderGeometry.toolbarFadeDistance, FuncSpacing.xl);
    expect(ReplicaProfileHeaderGeometry.initialExtentEstimate, 360);

    // Banner and identity scroll out with the content, one-to-one.
    expect(geometryAt(0).contentOffset, 0);
    expect(geometryAt(120).contentOffset, -120);

    final collapsed = geometryAt(430 - 56);
    expect(collapsed.isFullyCollapsed, isTrue);
    expect(geometryAt(430 - 56 - 0.6).isFullyCollapsed, isFalse);
  });

  test('the toolbar background fades in as the banner leaves it', () {
    const fadeStart =
        ReplicaProfileHeaderGeometry.bannerBelowToolbar -
        ReplicaProfileHeaderGeometry.toolbarFadeDistance;
    expect(geometryAt(0).toolbarOpacity, 0);
    expect(geometryAt(fadeStart).toolbarOpacity, 0);
    expect(
      geometryAt(
        fadeStart + ReplicaProfileHeaderGeometry.toolbarFadeDistance / 2,
      ).toolbarOpacity,
      0.5,
    );
    expect(
      geometryAt(
        ReplicaProfileHeaderGeometry.bannerBelowToolbar,
      ).toolbarOpacity,
      1,
    );
    expect(geometryAt(200).toolbarOpacity, 1);

    var previous = 0.0;
    for (
      var offset = 0.0;
      offset <= ReplicaProfileHeaderGeometry.bannerBelowToolbar;
      offset += 2
    ) {
      final opacity = geometryAt(offset).toolbarOpacity;
      expect(opacity, greaterThanOrEqualTo(previous));
      previous = opacity;
    }
  });

  test('controls read the banner only while it sits behind the toolbar', () {
    const mid =
        ReplicaProfileHeaderGeometry.bannerBelowToolbar -
        ReplicaProfileHeaderGeometry.toolbarFadeDistance / 2;
    expect(geometryAt(0).bannerBehindToolbar, isTrue);
    expect(geometryAt(mid - 0.1).bannerBehindToolbar, isTrue);
    expect(geometryAt(mid + 0.1).bannerBehindToolbar, isFalse);
    expect(
      geometryAt(
        ReplicaProfileHeaderGeometry.bannerBelowToolbar,
      ).bannerBehindToolbar,
      isFalse,
    );
  });

  test('the pinned toolbar includes the status-bar inset', () {
    expect(geometryAt(0, minExtent: 80).minExtent, 80);
    expect(geometryAt(0, minExtent: 80).collapseRange, 350);
  });

  test('the delegate estimates one frame until the identity reports', () {
    final estimating = ReplicaProfileHeaderDelegate(
      user: _user(42),
      isMe: true,
      selectedTabIndex: 0,
      showRestrictSelector: false,
      restrict: UserRestrict.public,
      onRestrictChanged: (_) {},
      onShare: (_) {},
      onExpandedExtentMeasured: (_) {},
    );
    expect(
      estimating.maxExtent,
      ReplicaProfileHeaderGeometry.initialExtentEstimate,
    );

    final measured = ReplicaProfileHeaderDelegate(
      user: _user(42),
      isMe: true,
      selectedTabIndex: 0,
      showRestrictSelector: false,
      restrict: UserRestrict.public,
      onRestrictChanged: (_) {},
      onShare: (_) {},
      expandedExtent: 247,
      onExpandedExtentMeasured: (_) {},
    );
    expect(measured.maxExtent, 247);
    expect(measured.minExtent, 56);
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
              _MeasuredProfileHeader(
                delegateFor: (extent, onMeasured) =>
                    ReplicaProfileHeaderDelegate(
                      user: _user(42),
                      isMe: true,
                      selectedTabIndex: 0,
                      showRestrictSelector: false,
                      restrict: UserRestrict.public,
                      onRestrictChanged: (_) {},
                      onShare: (_) {},
                      expandedExtent: extent,
                      onExpandedExtentMeasured: onMeasured,
                    ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 2000)),
            ],
          ),
        ),
      ),
    );
    // First frame lays out at the estimate extent; the measured height
    // lands on the second frame.
    await tester.pump();
    await tester.pump();
    final collapseRange = _headerCollapseRange(tester);

    controller.jumpTo(collapseRange * 0.8);
    await tester.pump();
    expect(find.byKey(const ValueKey('profile-toolbar-title')), findsNothing);

    controller.jumpTo(collapseRange - 0.6);
    await tester.pump();
    expect(find.byKey(const ValueKey('profile-toolbar-title')), findsNothing);

    controller.jumpTo(collapseRange);
    await tester.pump();
    expect(find.byKey(const ValueKey('profile-toolbar-title')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
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
                    _MeasuredProfileHeader(
                      delegateFor: (extent, onMeasured) =>
                          ReplicaProfileHeaderDelegate(
                            user: user,
                            isMe: true,
                            selectedTabIndex: 0,
                            showRestrictSelector: false,
                            restrict: UserRestrict.public,
                            onRestrictChanged: (_) {},
                            onShare: (_) {},
                            expandedExtent: extent,
                            onExpandedExtentMeasured: onMeasured,
                          ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 2000)),
                  ],
                ),
              ),
            ),
          );
          await tester.pump();
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
              if (step == 0) {
                // R2: the avatar's centre line sits exactly on the
                // banner's bottom edge — topInset(0) + toolbar(56) +
                // bannerBelowToolbar(80) = 136.
                expect(
                  tester.getRect(avatar).center.dy,
                  moreOrLessEquals(
                    kToolbarHeight +
                        ReplicaProfileHeaderGeometry.bannerBelowToolbar,
                    epsilon: 0.5,
                  ),
                );
              }
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
              _MeasuredProfileHeader(
                delegateFor: (extent, onMeasured) =>
                    ReplicaProfileHeaderDelegate(
                      user: _user(42),
                      isMe: true,
                      selectedTabIndex: 0,
                      showRestrictSelector: false,
                      restrict: UserRestrict.public,
                      onRestrictChanged: (_) {},
                      onShare: (_) {},
                      expandedExtent: extent,
                      onExpandedExtentMeasured: onMeasured,
                      topInset: 24,
                    ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 2000)),
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
              _MeasuredProfileHeader(
                delegateFor: (extent, onMeasured) =>
                    ReplicaProfileHeaderDelegate(
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
                      expandedExtent: extent,
                      onExpandedExtentMeasured: onMeasured,
                      topInset: 24,
                    ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 2000)),
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
                _MeasuredProfileHeader(
                  delegateFor: (extent, onMeasured) =>
                      ReplicaProfileHeaderDelegate(
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
                        expandedExtent: extent,
                        onExpandedExtentMeasured: onMeasured,
                      ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 2000)),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byTooltip('分享用户'), findsOneWidget);
      // The owner's main action is a tonal text button on the page
      // surface — not an icon button anymore.
      expect(find.text('编辑个人资料'), findsOneWidget);
      // The persistent overflow carries the full list in every state.
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('分享用户'), findsOneWidget);
      // Inline main action + menu item.
      expect(find.text('编辑个人资料'), findsNWidgets(2));
      expect(find.text('公开'), findsOneWidget);
      expect(find.text('私密'), findsOneWidget);
      expect(find.text('收藏标签'), findsOneWidget);
      expect(find.text('下载全部作品'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      controller.jumpTo(_headerCollapseRange(tester));
      await tester.pump();
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('分享用户'), findsOneWidget);
      // Collapsed: the inline identity is offstage, only the menu item.
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
          _MeasuredProfileHeader(
            delegateFor: (extent, onMeasured) => ReplicaProfileHeaderDelegate(
              user: _user(42),
              isMe: true,
              selectedTabIndex: 0,
              showRestrictSelector: false,
              restrict: UserRestrict.public,
              onRestrictChanged: (_) {},
              onShare: (_) {},
              expandedExtent: extent,
              onExpandedExtentMeasured: onMeasured,
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
            _MeasuredProfileHeader(
              delegateFor: (extent, onMeasured) => ReplicaProfileHeaderDelegate(
                user: _user(42),
                isMe: true,
                selectedTabIndex: 0,
                showRestrictSelector: false,
                restrict: UserRestrict.public,
                onRestrictChanged: (_) {},
                onShare: (_) => shareCount++,
                expandedExtent: extent,
                onExpandedExtentMeasured: onMeasured,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 2000)),
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

      // The collapse range comes from the measured header extent.
      for (final progress in [0.60, 0.80, 0.95]) {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        controller.jumpTo(_headerCollapseRange(tester) * progress);
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
    'cover artwork switches the persistent controls to the overlay style',
    (tester) async {
      final controller = ScrollController();
      final coverUser = _user(
        42,
      ).copyWith(backgroundImageUrl: 'https://i.pximg.net/bg.png');
      Widget header() => Scaffold(
        body: CustomScrollView(
          controller: controller,
          slivers: [
            _MeasuredProfileHeader(
              delegateFor: (extent, onMeasured) => ReplicaProfileHeaderDelegate(
                user: coverUser,
                isMe: true,
                selectedTabIndex: 0,
                showRestrictSelector: false,
                restrict: UserRestrict.public,
                onRestrictChanged: (_) {},
                onShare: (_) {},
                expandedExtent: extent,
                onExpandedExtentMeasured: onMeasured,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 2000)),
          ],
        ),
      );
      await mockNetworkImagesFor(() async {
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

        ButtonStyle? overflowStyle() => tester
            .widget<AppMenuButton<dynamic>>(
              find.byWidgetPredicate((w) => w is AppMenuButton),
            )
            .style;

        // Expanded over artwork: the back affordance is the shared overlay
        // button and the overflow carries the same imageControl fill (R4).
        expect(
          find.ancestor(
            of: find.byIcon(Icons.arrow_back_ios_new),
            matching: find.byType(ImageOverlayButton),
          ),
          findsOneWidget,
        );
        expect(
          overflowStyle()!.backgroundColor!.resolve(const <WidgetState>{}),
          FuncTokens.imageControl,
        );

        // Collapsed onto the plain surface: no overlay button, no fill,
        // but both controls stay mounted and tappable.
        controller.jumpTo(_headerCollapseRange(tester));
        await tester.pump();
        expect(find.byType(ImageOverlayButton), findsNothing);
        expect(overflowStyle(), isNull);
        expect(find.byIcon(Icons.more_vert), findsOneWidget);
        expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      });
      controller.dispose();
    },
  );

  testWidgets('without a cover the header controls stay plain surface icons', (
    tester,
  ) async {
    final controller = ScrollController();
    Widget header() => Scaffold(
      body: CustomScrollView(
        controller: controller,
        slivers: [
          _MeasuredProfileHeader(
            delegateFor: (extent, onMeasured) => ReplicaProfileHeaderDelegate(
              user: _user(42),
              isMe: true,
              selectedTabIndex: 0,
              showRestrictSelector: false,
              restrict: UserRestrict.public,
              onRestrictChanged: (_) {},
              onShare: (_) {},
              expandedExtent: extent,
              onExpandedExtentMeasured: onMeasured,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 2000)),
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

    // The banner still sits behind the toolbar while expanded, but with
    // no cover there is nothing to overlay — plain icons, no fill (R4).
    expect(find.byType(ImageOverlayButton), findsNothing);
    expect(
      tester
          .widget<AppMenuButton<dynamic>>(
            find.byWidgetPredicate((w) => w is AppMenuButton),
          )
          .style,
      isNull,
    );
    expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'the status bar asks for light icons only over a live cover banner',
    (tester) async {
      final controller = ScrollController();
      Widget app(UserEntity user) => MaterialApp(
        theme: replicaTheme(Brightness.light),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Scaffold(
          body: CustomScrollView(
            controller: controller,
            slivers: [
              _MeasuredProfileHeader(
                delegateFor: (extent, onMeasured) =>
                    ReplicaProfileHeaderDelegate(
                      user: user,
                      isMe: true,
                      selectedTabIndex: 0,
                      showRestrictSelector: false,
                      restrict: UserRestrict.public,
                      onRestrictChanged: (_) {},
                      onShare: (_) {},
                      expandedExtent: extent,
                      onExpandedExtentMeasured: onMeasured,
                    ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 2000)),
            ],
          ),
        ),
      );

      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          app(
            _user(
              42,
            ).copyWith(backgroundImageUrl: 'https://i.pximg.net/bg.png'),
          ),
        );
        // latestStyle lands in a following microtask (C2 §9): pump once,
        // then once more before reading.
        await tester.pump();
        await tester.pump();
        expect(
          SystemChrome.latestStyle?.statusBarIconBrightness,
          Brightness.light,
          reason: 'an expanded cover must paint light status-bar icons',
        );

        controller.jumpTo(_headerCollapseRange(tester));
        await tester.pump();
        await tester.pump();
        expect(
          SystemChrome.latestStyle?.statusBarIconBrightness,
          Brightness.dark,
          reason: 'the collapsed toolbar restores the light-theme default',
        );
      });

      await tester.pumpWidget(app(_user(42)));
      await tester.pump();
      await tester.pump();
      expect(
        SystemChrome.latestStyle?.statusBarIconBrightness,
        Brightness.dark,
        reason: 'a cover-less banner keeps the root default',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'stale profile error banner can be dismissed without hiding the snapshot',
    (tester) async {
      final repository = _FakeUserRepository(
        detailFailure: const ApiNetworkError('offline'),
      );
      final container = await _makeWorld(users: repository);
      container.read(userStoreProvider.notifier).mergeAll([_user(42)]);
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

      expect(find.byType(MaterialBanner), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-stale-error-retry')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-stale-error-dismiss')),
        findsOneWidget,
      );
      expect(find.text('ApiNetworkError(network error)'), findsNothing);
      expect(find.text('sample user'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('profile-stale-error-dismiss')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MaterialBanner), findsNothing);
      expect(find.text('sample user'), findsOneWidget);
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

      // D3: the work-section selector is the shared compact type switch
      // inside the feed — a <=48dp segmented row, never the old ChoiceChip
      // strip pinned under the tab bar.
      final typeSwitch = find.byType(AppTypeSwitch<ProfileWorkSection>);
      expect(typeSwitch, findsOneWidget);
      expect(
        tester.getSize(typeSwitch).height,
        lessThanOrEqualTo(kMinInteractiveDimension),
      );
      expect(find.byType(ChoiceChip), findsNothing);
      final segments = find.byType(SegmentedButton<ProfileWorkSection>);
      expect(segments, findsOneWidget);
      for (final label in ['插画', '漫画', '小说', '系列']) {
        expect(
          find.widgetWithText(SegmentedButton<ProfileWorkSection>, label),
          findsOneWidget,
        );
      }
      expect(find.byType(EasyRefresh), findsOneWidget);
      expect(find.byType(HeaderLocator), findsOneWidget);

      // Re-tapping a non-work tab must never open the work-type selector.
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(typeSwitch, findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
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
            .widget<SegmentedButton<ProfileWorkSection>>(
              find.byType(SegmentedButton<ProfileWorkSection>),
            )
            .selected,
        {ProfileWorkSection.manga},
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
            .widget<SegmentedButton<ProfileWorkSection>>(
              find.byType(SegmentedButton<ProfileWorkSection>),
            )
            .selected,
        {ProfileWorkSection.series},
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
            .widget<SegmentedButton<ProfileWorkSection>>(
              find.byType(SegmentedButton<ProfileWorkSection>),
            )
            .selected,
        {ProfileWorkSection.manga},
      );
    },
  );

  testWidgets(
    'profile statistics lay out in an equal-width grid without horizontal '
    'scrolling',
    (tester) async {
      const statIds = [
        'following',
        'myPixiv',
        'illust',
        'manga',
        'novel',
        'series',
      ];
      Finder stat(String id) => find.byKey(ValueKey('profile-stat-$id-header'));

      Future<void> pumpPage({
        required Size size,
        required double textScale,
        required Locale locale,
      }) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final container = await _makeWorld(users: _FakeUserRepository());
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: locale,
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
                child: const UserPage(userId: 42),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      void expectNoHorizontalScrollable(Finder statFinder) {
        var found = false;
        tester.element(statFinder).visitAncestorElements((ancestor) {
          final widget = ancestor.widget;
          if (widget is Scrollable && widget.axis == Axis.horizontal) {
            found = true;
          }
          return true;
        });
        expect(found, isFalse, reason: 'stat cell must not scroll sideways');
      }

      void expectEqualRowWidths() {
        final rects = [for (final id in statIds) tester.getRect(stat(id))];
        final rows = <double, List<Rect>>{};
        for (final rect in rects) {
          rows.putIfAbsent(rect.top, () => []).add(rect);
        }
        for (final row in rows.values) {
          for (final cell in row) {
            expect(
              cell.width,
              moreOrLessEquals(row.first.width, epsilon: 0.01),
              reason: 'cells in one grid row share the same width',
            );
          }
        }
      }

      // 411×891, 1.0, zh: all six stats fit one row, all on screen.
      await pumpPage(
        size: const Size(411, 891),
        textScale: 1,
        locale: const Locale('zh', 'CN'),
      );
      for (final id in statIds) {
        final rect = tester.getRect(stat(id));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(891));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(411));
        expectNoHorizontalScrollable(stat(id));
      }
      final tops = {for (final id in statIds) tester.getRect(stat(id)).top};
      expect(
        tops,
        hasLength(1),
        reason: '411/1.0/zh fits six cells in one row',
      );
      expectEqualRowWidths();

      // Narrow/large-text conditions that wrap onto multiple rows live in
      // test/profile_statistics_test.dart — the legacy fixed-height header
      // cannot host a taller grid at all, so T3's R1 tests own the
      // 360×640 × ru combinations on the real page.
    },
  );

  // R8 wide-screen: the measured header lays out cleanly and all six
  // statistics share one row when there is room for them.
  testWidgets('wide screens keep the statistics on one row', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = await _makeWorld(users: _FakeUserRepository());
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
    expect(tester.takeException(), isNull);

    final tops = <double>{
      for (final id in [
        'following',
        'myPixiv',
        'illust',
        'manga',
        'novel',
        'series',
      ])
        tester.getRect(find.byKey(ValueKey('profile-stat-$id-header'))).top,
    };
    expect(tops, hasLength(1), reason: '1200dp fits six cells in one row');
  });

  testWidgets('the expanded header is measured from its content', (
    tester,
  ) async {
    const statIds = [
      'following',
      'myPixiv',
      'illust',
      'manga',
      'novel',
      'series',
    ];
    Finder stat(String id) => find.byKey(ValueKey('profile-stat-$id-header'));

    Future<void> pumpPage({
      required bool isMe,
      required bool cover,
      required Size size,
      required double textScale,
      required Locale locale,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final repository = _FakeUserRepository(
        detail: _user(42).copyWith(
          backgroundImageUrl: cover ? 'https://i.pximg.net/bg.png' : null,
        ),
      );
      final container = await _makeWorld(users: repository);
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: locale,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: isMe
                  ? MePage(onEditProfile: () {})
                  : const UserPage(userId: 42),
            ),
          ),
        );
        await tester.pumpAndSettle();
      });
    }

    void expectIdentityInsideHeader(String label, {required bool isMe}) {
      // No layout exception was recorded while building this combination.
      expect(tester.takeException(), isNull, reason: label);
      // The pinned tab strip is laid out even when a measured header that
      // is taller than the viewport pushes it below the fold — the sliver
      // reports `visible: false` then, so the on-stage finder misses it.
      // skipOffstage keeps the anchor: its rect still sits at the header's
      // bottom edge, which is exactly what the assertions measure against.
      final tabTop = tester
          .getRect(find.byType(TabBar, skipOffstage: false))
          .top;
      // Main action + share live in the identity band above the tab strip.
      final main = isMe
          ? find.byType(FilledButton)
          : find.byType(FollowSwitchButton);
      expect(main, findsOneWidget, reason: label);
      expect(
        tester.getRect(main).bottom,
        lessThanOrEqualTo(tabTop),
        reason: '$label main action leaves the header',
      );
      final share = find.byIcon(Icons.share_outlined);
      expect(share, findsOneWidget, reason: label);
      expect(
        tester.getRect(share).bottom,
        lessThanOrEqualTo(tabTop),
        reason: '$label share leaves the header',
      );
      for (final id in statIds) {
        expect(
          tester.getRect(stat(id)).bottom,
          lessThanOrEqualTo(tabTop),
          reason: '$label stat $id leaves the header',
        );
      }
    }

    for (final size in [const Size(360, 640), const Size(411, 891)]) {
      final small = size.width == 360;
      for (final isMe in [true, false]) {
        for (final cover in [true, false]) {
          await pumpPage(
            isMe: isMe,
            cover: cover,
            size: size,
            textScale: small ? 2 : 1,
            locale: small ? const Locale('ru') : const Locale('zh', 'CN'),
          );
          expectIdentityInsideHeader(
            '${size.width}×${size.height} isMe=$isMe cover=$cover',
            isMe: isMe,
          );
        }
      }
    }
    tester.view.reset();
  });

  testWidgets('the measured extent tracks refreshed identity content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository = _FakeUserRepository(
      detail: _user(42).copyWith(account: 'sample'),
    );
    final container = await _makeWorld(users: repository);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const UserPage(userId: 42),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // From the second frame on, the header is fully opaque — the estimate
    // frame only exists before the identity reports its height.
    final opacities = tester.widgetList<Opacity>(
      find.ancestor(
        of: find.byKey(const ValueKey('profile-expanded-avatar')),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacities, isNotEmpty);
    for (final opacity in opacities) {
      expect(opacity.opacity, 1);
    }
    final tabTopBefore = tester
        .getRect(find.byType(TabBar, skipOffstage: false))
        .top;

    // A refreshed user with a much longer account line wraps to more rows,
    // which must grow the measured extent instead of overflowing. The page
    // reads the entity captured by userDetailControllerProvider, so the
    // refresh has to go through reload() — a bare UserStore.mergeAll never
    // reaches it.
    repository.detail = _user(42).copyWith(
      name: 'an extremely long display name that keeps going',
      account: 'a_very_long_account_handle_that_wraps_to_more_lines',
    );
    await container.read(userDetailControllerProvider(42).notifier).reload();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final tabTopAfter = tester
        .getRect(find.byType(TabBar, skipOffstage: false))
        .top;
    expect(
      tabTopAfter,
      greaterThan(tabTopBefore),
      reason: 'the measured extent follows wrapped identity content',
    );
    for (final id in ['following', 'illust', 'series']) {
      expect(
        tester.getRect(find.byKey(ValueKey('profile-stat-$id-header'))).bottom,
        lessThanOrEqualTo(tabTopAfter),
      );
    }
  });

  testWidgets('header height tracks the drag without jumps', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository = _FakeUserRepository(
      works: List.generate(30, (index) => _illust(index + 1)),
    );
    final container = await _makeWorld(users: repository);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('ru'),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Drag target: the nested scroll view itself. At 360×640 with 2x
      // text the measured header is taller than the viewport, so the feed
      // slivers are entirely below the fold — finders treat them as
      // offstage and `tester.drag(feed)` cannot resolve a hit point. The
      // NestedScrollView's centre is the same screen point the gesture
      // would land on anyway.
      final scrollable = find.byType(NestedScrollView);
      double tabTop() =>
          tester.getRect(find.byType(TabBar, skipOffstage: false)).top;

      var previous = tabTop();
      final tops = <double>[previous];
      for (var step = 0; step < 14; step++) {
        await tester.drag(scrollable, const Offset(0, -30));
        await tester.pump();
        final top = tabTop();
        // Monotone, and never ahead of the finger: the height change per
        // frame cannot exceed the dragged distance.
        expect(top, lessThanOrEqualTo(previous + 0.01));
        expect(previous - top, lessThanOrEqualTo(30.1));
        tops.add(top);
        previous = top;
      }
      for (var step = 0; step < 14; step++) {
        await tester.drag(scrollable, const Offset(0, 30));
        await tester.pump();
        final top = tabTop();
        expect(top, greaterThanOrEqualTo(previous - 0.01));
        expect(top - previous, lessThanOrEqualTo(30.1));
        previous = top;
      }
      expect(tester.takeException(), isNull);
      expect(tabTop(), tops.first);
      // Flush any overscroll/refresh timers the reverse drags armed so the
      // test does not leave a pending Timer behind.
      await tester.pumpAndSettle();
    });
  });

  // The device's outer Scrollable inside the profile NestedScrollView —
  // first in tree order, before any tab feed.
  ScrollPosition outerPosition(WidgetTester tester) {
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
    return tester.state<ScrollableState>(outerScrollable).position;
  }

  // The active tab feed's own Scrollable inside the NestedScrollView body.
  ScrollPosition activeFeedPosition(WidgetTester tester) {
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
    return tester.state<ScrollableState>(innerScrollable).position;
  }

  testWidgets(
    'a light upward fling never leaves the inner feed ahead of the header',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final speed in [300.0, 600.0]) {
        final repository = _FakeUserRepository(
          works: List.generate(30, (index) => _illust(index + 1)),
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
                scrollBehavior: const FuncScrollBehavior(),
                home: const UserPage(userId: 42),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final outer = outerPosition(tester);
          final inner = activeFeedPosition(tester);
          final maxExtent = outer.maxScrollExtent;
          expect(maxExtent, greaterThan(0));

          // Drag just short of the collapse edge, then release at the
          // measured speed — the coordinator starts one ballistic on each
          // position over the combined metrics.
          await tester.flingFrom(
            tester.getCenter(find.byType(NestedScrollView)),
            Offset(0, -(maxExtent - 60)),
            speed,
          );
          // The invariant: while the header is still collapsing the feed
          // must not have started scrolling. A divergent inner simulation
          // breaks it — inner rolls while outer is still short of the end.
          var frames = 0;
          while (frames < 240) {
            await tester.pump(const Duration(milliseconds: 16));
            if (outer.pixels >= maxExtent - 0.001) break;
            expect(
              inner.pixels,
              lessThanOrEqualTo(0.001),
              reason:
                  'v=$speed frame $frames: outer=${outer.pixels} of '
                  '$maxExtent — the inner feed rolled before the header '
                  'finished collapsing',
            );
            if (!outer.isScrollingNotifier.value &&
                !inner.isScrollingNotifier.value) {
              break;
            }
            frames++;
          }
          // Settle: either the header finished collapsing (inner may then
          // roll), or everything stopped inside bounds.
          await tester.pumpAndSettle();
          expect(
            outer.pixels >= maxExtent - 0.001 || inner.pixels <= 0.001,
            isTrue,
            reason:
                'v=$speed: settled at outer=${outer.pixels}/$maxExtent, '
                'inner=${inner.pixels} — inconsistent stop positions',
          );
        });
      }
    },
  );

  testWidgets(
    'a light pull-down while the header is collapsing keeps it expanding',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = _FakeUserRepository(
        works: List.generate(30, (index) => _illust(index + 1)),
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
              scrollBehavior: const FuncScrollBehavior(),
              home: const UserPage(userId: 42),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final outer = outerPosition(tester);
        final inner = activeFeedPosition(tester);
        final maxExtent = outer.maxScrollExtent;
        expect(maxExtent, greaterThan(0));

        // The state a light collapse fling leaves on the buggy build:
        // header collapsed, feed already mid-scroll.
        outer.jumpTo(maxExtent);
        inner.jumpTo(115);
        await tester.pump();

        // A deliberate ~80px pull released at low speed: the inner feed
        // slides back to 0 and the leftover momentum must expand the
        // header, not die at the boundary.
        await tester.flingFrom(
          tester.getCenter(find.byType(NestedScrollView)),
          const Offset(0, 80),
          300,
        );
        var frames = 0;
        while (frames < 240 &&
            (outer.isScrollingNotifier.value ||
                inner.isScrollingNotifier.value)) {
          await tester.pump(const Duration(milliseconds: 16));
          frames++;
        }
        await tester.pumpAndSettle();
        expect(inner.pixels, closeTo(0, 0.001));
        expect(
          outer.pixels,
          lessThan(maxExtent - 0.5),
          reason:
              'after the feed reached its top the pull must keep expanding '
              'the header — outer=${outer.pixels} of $maxExtent',
        );
      });
    },
  );

  testWidgets('a pull at the very top still pulls to refresh', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository = _FakeUserRepository(
      works: List.generate(30, (index) => _illust(index + 1)),
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
            scrollBehavior: const FuncScrollBehavior(),
            home: const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final outer = outerPosition(tester);
      expect(outer.pixels, 0);
      final firstLoads = repository.requests
          .where((request) => request == 'works:42:illust:first')
          .length;

      // A deliberate pull past the 100dp arm threshold, then release.
      await tester.drag(find.byType(NestedScrollView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(
        repository.requests
            .where((request) => request == 'works:42:illust:first')
            .length,
        firstLoads + 1,
        reason: 'the top pull must still reach the feed refresh',
      );
      expect(outer.pixels, 0);
    });
  });

  /// The work type row is the first sliver of a feed inside
  /// PullToRefresh: the shared row contract re-checked on a real feed.
  group('the work type row on a real feed', () {
    Future<_FakeUserRepository> pumpProfile(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = _FakeUserRepository(
        works: List.generate(30, (index) => _illust(index + 1)),
      );
      final container = await _makeWorld(users: repository);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            scrollBehavior: const FuncScrollBehavior(),
            home: const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return repository;
    }

    int firstLoads(_FakeUserRepository repository) => repository.requests
        .where((request) => request == 'works:42:illust:first')
        .length;

    testWidgets('a sideways swipe on the row never pulls to refresh', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final repository = await pumpProfile(tester);
        final segments = find.byType(SegmentedButton<ProfileWorkSection>);
        expect(segments.hitTestable(), findsOneWidget);
        final before = firstLoads(repository);

        await tester.drag(segments, const Offset(300, 0));
        await tester.pumpAndSettle();
        expect(firstLoads(repository), before);
      });
    });

    testWidgets('a pull under the threshold carries the row with the list', (
      tester,
    ) async {
      await mockNetworkImagesFor(() async {
        final repository = await pumpProfile(tester);
        final row = find.byType(AppTypeSwitch<ProfileWorkSection>);
        // The tall header leaves the cards just below the fold; they are
        // laid out all the same.
        final card = find.byType(IllustCard).first;
        final before = firstLoads(repository);
        final rowTop = tester.getRect(row).top;
        final cardTop = tester.getRect(card).top;

        // 60px < the 100px trigger — the gesture stays a drag.
        final gesture = await tester.startGesture(tester.getCenter(row));
        for (var i = 0; i < 6; i++) {
          await gesture.moveBy(const Offset(0, 10));
          await tester.pump();
        }
        final cardDelta = tester.getRect(card).top - cardTop;
        expect(cardDelta, greaterThan(0));
        expect(
          tester.getRect(row).top - rowTop,
          moreOrLessEquals(cardDelta, epsilon: 0.01),
        );

        await gesture.up();
        await tester.pumpAndSettle();
        expect(firstLoads(repository), before);
      });
    });
  });

  testWidgets('the banner without a cover is a container, not the page '
      'colour', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              _MeasuredProfileHeader(
                delegateFor: (extent, onMeasured) =>
                    ReplicaProfileHeaderDelegate(
                      user: _user(42),
                      isMe: true,
                      selectedTabIndex: 0,
                      showRestrictSelector: false,
                      restrict: UserRestrict.public,
                      onRestrictChanged: (_) {},
                      onShare: (_) {},
                      expandedExtent: extent,
                      onExpandedExtentMeasured: onMeasured,
                    ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 2000)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final headerMaterial = find
        .ancestor(
          of: find.byKey(const ValueKey('profile-expanded-avatar')),
          matching: find.byType(Material),
        )
        .first;
    final colors = Theme.of(tester.element(headerMaterial)).colorScheme;
    final banners = tester
        .widgetList<ColoredBox>(
          find.descendant(
            of: headerMaterial,
            matching: find.byType(ColoredBox),
          ),
        )
        .where((box) => box.color == colors.surfaceContainerHigh)
        .toList();
    expect(banners, hasLength(1));
    expect(tester.widget<Material>(headerMaterial).color, colors.surface);
    expect(colors.surfaceContainerHigh, isNot(colors.surface));
  });

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
        // The switch row scrolled away with the feed; a small reverse drag
        // floats it back in so the re-tap can land (Compact Type Switch
        // Contract).
        await tester.drag(
          find.byKey(
            const PageStorageKey(
              ProfileFeedKey(
                userId: 42,
                kind: ProfileFeedKind.work,
                workType: UserWorkType.illust,
              ),
            ),
          ),
          const Offset(0, 50),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(SegmentedButton<ProfileWorkSection>),
            matching: find.text('插画'),
          ),
        );
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

  testWidgets('work type switch swaps between all four feed sections', (
    tester,
  ) async {
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

    final segments = find.byType(SegmentedButton<ProfileWorkSection>);
    Finder segment(String label) =>
        find.descendant(of: segments, matching: find.text(label));
    Set<ProfileWorkSection> selected() =>
        tester.widget<SegmentedButton<ProfileWorkSection>>(segments).selected;

    expect(segments, findsOneWidget);
    expect(selected(), {ProfileWorkSection.illust});
    expect(repository.requests, contains('works:42:illust:first'));

    await tester.tap(segment('漫画'));
    await tester.pumpAndSettle();
    expect(selected(), {ProfileWorkSection.manga});
    expect(repository.requests, contains('works:42:manga:first'));

    // Novel and series are their own feeds; the selector follows whichever
    // feed is mounted.
    await tester.tap(segment('小说'));
    await tester.pumpAndSettle();
    expect(selected(), {ProfileWorkSection.novel});
    expect(find.byType(ProfileNovelFeed), findsOneWidget);

    await tester.tap(segment('系列'));
    await tester.pumpAndSettle();
    expect(selected(), {ProfileWorkSection.series});
    expect(find.byType(UserSeriesFeed), findsOneWidget);

    await tester.tap(segment('插画'));
    await tester.pumpAndSettle();
    expect(selected(), {ProfileWorkSection.illust});
    expect(find.byType(ProfileIllustFeed), findsOneWidget);
  });

  testWidgets(
    'a pending profile shows the skeleton and the back button leaves',
    (tester) async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final repository = _FakeUserRepository()..detailGate = gate;
      final container = await _makeWorld(users: repository);

      // Push the page so canPop is true — the skeleton's BackButton is a
      // real affordance, not a dead icon.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const UserPage(userId: 42),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(ProfileSkeleton), findsOneWidget);
      expect(find.byType(FeedEmpty), findsNothing);
      expect(find.byType(FeedLoading), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(UserPage), findsNothing);

      gate.complete();
      await tester.pump();
    },
  );

  for (final textScale in const [1.0, 1.3]) {
    testWidgets(
      'the profile skeleton lines up with the header it stands in for '
      '(412dp @ ${textScale}x text)',
      (tester) async {
        tester.view.physicalSize = const Size(412, 892);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final repository = _FakeUserRepository()..detailGate = gate;
        final container = await _makeWorld(users: repository);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: const UserPage(userId: 42),
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(ProfileSkeleton), findsOneWidget);
        final avatarBone = tester.getCenter(
          find.byKey(const ValueKey('profile-skeleton-avatar')),
        );
        final nameBone = tester.getTopLeft(
          find.byKey(const ValueKey('profile-skeleton-name')),
        );
        final tabSlot = tester.getTopLeft(
          find.byKey(const ValueKey('profile-skeleton-tabs')),
        );

        gate.complete();
        // The works feed shimmers behind the header, so pumpAndSettle would
        // never return; pump a fixed stretch for the header to measure itself.
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.byType(ProfileSkeleton), findsNothing);
        final avatar = tester.getCenter(
          find.byKey(const ValueKey('profile-expanded-avatar')),
        );
        final name = tester.getTopLeft(
          find.byKey(const ValueKey('profile-expanded-name')),
        );
        final tabs = tester.getTopLeft(
          find.byKey(const ValueKey('profile-tabs')),
        );

        // Same avatar centre, the same name baseline row and the same tab
        // band top edge: nothing jumps when the data replaces the bones.
        expect(avatarBone.dx, moreOrLessEquals(avatar.dx));
        expect(avatarBone.dy, moreOrLessEquals(avatar.dy));
        expect(nameBone.dx, moreOrLessEquals(name.dx));
        expect(nameBone.dy, moreOrLessEquals(name.dy));
        expect(tabSlot.dy, moreOrLessEquals(tabs.dy, epsilon: 1.0));
      },
    );
  }

  testWidgets('work type switch stays usable while the feed is still loading', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final repository = _FakeUserRepository()..worksGate = gate;
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
    // The detail resolves but the works request is parked behind the
    // gate: the feed renders its first-load skeleton, which must still
    // carry the selector (D3 loading/error contract). pumpAndSettle can't
    // settle on the shimmer's perpetual animation, so pump a fixed
    // stretch.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(repository.requests, contains('works:42:illust:first'));
    expect(find.byType(IllustGridSkeleton), findsOneWidget);
    final segments = find.byType(SegmentedButton<ProfileWorkSection>);
    expect(segments, findsOneWidget);
    await tester.tap(find.descendant(of: segments, matching: find.text('漫画')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(repository.requests, contains('works:42:manga:first'));
  });

  testWidgets(
    'work type switch floats back in on a small reverse drag while the '
    'header stays collapsed',
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

        const feedKey = ProfileFeedKey(
          userId: 42,
          kind: ProfileFeedKind.work,
          workType: UserWorkType.illust,
        );
        final feed = find.byKey(const PageStorageKey(feedKey));
        final typeRow = find.byType(AppTypeSwitch<ProfileWorkSection>);
        expect(typeRow.hitTestable(), findsOneWidget);

        // Scroll the inner feed: the switch row scrolls away with the
        // content and the outer header collapses.
        await tester.drag(feed, const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(typeRow.hitTestable(), findsNothing);
        expect(
          find.byKey(const ValueKey('profile-toolbar-title')),
          findsOneWidget,
        );

        // A small reverse drag floats the row back in. The inner position
        // consumes the delta, so the outer header stays collapsed.
        await tester.drag(feed, const Offset(0, 50));
        await tester.pumpAndSettle();
        expect(typeRow.hitTestable(), findsOneWidget);
        expect(
          find.byKey(const ValueKey('profile-toolbar-title')),
          findsOneWidget,
        );
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
    const labelSize = 14.0;

    Future<void> pumpTabs(
      WidgetTester tester, {
      required Locale locale,
      required bool isMe,
      double width = 411,
      double textScale = 1,
    }) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TabController(length: isMe ? 5 : 4, vsync: tester);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: replicaTheme(Brightness.light),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: CustomScrollView(
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: ReplicaProfileTabsDelegate(
                      controller: controller,
                      isMe: isMe,
                      onTabTap: (_) {},
                    ),
                  ),
                  const SliverFillRemaining(),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    double labelFontSize(WidgetTester tester) {
      final text = tester.widget<RichText>(
        find
            .descendant(
              of: find.byType(Tab).first,
              matching: find.byType(RichText),
            )
            .first,
      );
      return (text.text as TextSpan).style!.fontSize!;
    }

    testWidgets('isMe zh labels share equal-width slots at natural size', (
      tester,
    ) async {
      await pumpTabs(tester, locale: const Locale('zh', 'CN'), isMe: true);
      final bar = tester.widget<TabBar>(find.byType(TabBar));
      expect(bar.isScrollable, isFalse);
      expect(bar.tabAlignment, TabAlignment.fill);
      // Slots live in the Expanded wrappers; a Tab's own box keeps its
      // natural label size even when the bar fills the row.
      final widths = [
        for (var i = 0; i < 5; i++)
          tester
              .getRect(
                find.ancestor(
                  of: find.byType(Tab).at(i),
                  matching: find.byType(Expanded),
                ),
              )
              .width,
      ];
      for (final width in widths) {
        expect(width, moreOrLessEquals(widths.first, epsilon: 0.01));
      }
      expect(labelFontSize(tester), labelSize);
    });

    testWidgets('zh labels scroll at 2x text scale, still at 14sp', (
      tester,
    ) async {
      // R5: fitting is decided by measurement — labels never shrink.
      await pumpTabs(
        tester,
        locale: const Locale('zh', 'CN'),
        isMe: true,
        textScale: 2,
      );
      final bar = tester.widget<TabBar>(find.byType(TabBar));
      expect(bar.isScrollable, isTrue);
      expect(labelFontSize(tester), labelSize);
    });

    testWidgets('en labels scroll at full size instead of shrinking', (
      tester,
    ) async {
      // The old delegate scaled "Following" into the equal slot; now the
      // row keeps 14sp and scrolls — the AppTabBar contract.
      await pumpTabs(tester, locale: const Locale('en'), isMe: false);
      final bar = tester.widget<TabBar>(find.byType(TabBar));
      expect(bar.isScrollable, isTrue);
      expect(bar.tabAlignment, TabAlignment.start);
      expect(labelFontSize(tester), labelSize);
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
      // tabs, the feed-hosted type switch, and the header action row —
      // stays mounted (parent §6 gate: chrome survives
      // loading/error/empty).
      expect(repository.requests, contains('works:42:illust:first'));
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.byType(AppTypeSwitch<ProfileWorkSection>), findsOneWidget);
      for (final label in ['插画', '漫画', '小说', '系列']) {
        expect(
          find.widgetWithText(SegmentedButton<ProfileWorkSection>, label),
          findsOneWidget,
        );
      }
      expect(find.byType(ChoiceChip), findsNothing);
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
                    onTabTap: (_) {},
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
