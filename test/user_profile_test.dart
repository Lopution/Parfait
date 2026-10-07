import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/platform/android_intent_channel.dart';
import 'package:parfait/core/share/share_service.dart';
import 'package:parfait/core/user/follow_actions.dart';
import 'package:parfait/core/user/follow_store.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/core/user/user_detail_controller.dart';
import 'package:parfait/core/user/user_repository.dart';
import 'package:parfait/core/user/user_store.dart';
import 'package:parfait/core/profile/profile_models.dart';
import 'package:parfait/app/motion/state_fade.dart';
import 'package:parfait/app/scroll_behavior.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/func_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_menu_button.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/features/profile/profile_header_delegate.dart';
import 'package:parfait/features/profile/profile_novel_feed.dart';
import 'package:parfait/features/profile/user_page.dart';
import 'package:parfait/features/profile/profile_skeleton.dart';
import 'package:parfait/features/profile/user_series_feed.dart';
import 'package:parfait/app/widgets/follow_switch_button.dart';
import 'package:parfait/app/widgets/image_overlay_button.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/bookmark_world.dart';
import 'helpers/profile_world.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';

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

Future<void> _pumpProfile(
  WidgetTester tester,
  ProviderContainer container, {
  int userId = 42,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: promptHostBuilder,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: UserPage(userId: userId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<String> _tabLabels(WidgetTester tester) => [
  for (final tab in tester.widget<TabBar>(find.byType(TabBar)).tabs)
    ((tab as Tab).child! as Text).data!,
];

int _selectedTabIndex(WidgetTester tester) =>
    tester.widget<TabBar>(find.byType(TabBar)).controller!.index;

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
      final repository = FakeFollowRepository()..gate = gate;
      final container = await makeProfileWorld(follows: repository);
      final userStore = container.read(userStoreProvider.notifier);
      userStore.mergeAll([sampleUser(42)]);

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
      final repository = FakeFollowRepository()
        ..failure = StateError('offline');
      final container = await makeProfileWorld(follows: repository);
      final userStore = container.read(userStoreProvider.notifier);
      userStore.mergeAll([sampleUser(42)]);

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
      final container = await makeProfileWorld(twoAccounts: true);
      final userStore = container.read(userStoreProvider.notifier);
      final follows = container.read(followStoreProvider.notifier);
      userStore.mergeAll([sampleUser(42)]);
      follows.observeRemote(42, followed: true, snapshotRevision: 0);

      await container.read(accountStoreProvider.notifier).switchAccount('200');
      await Future<void>.delayed(Duration.zero);

      expect(container.read(userStoreProvider), isEmpty);
      expect(container.read(followStoreProvider), isEmpty);
    },
  );

  test('a page of users lands its follow snapshots as one write', () async {
    final container = await makeProfileWorld();
    var writes = 0;
    container.listen(followStoreProvider, (_, _) => writes++);
    final users = [
      for (var id = 300; id < 330; id++)
        sampleUser(id).copyWith(isFollowed: id.isEven),
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
    final container = await makeProfileWorld();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          builder: promptHostBuilder,
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
      user: sampleUser(42),
      isMe: true,
      selectedTabIndex: 0,
      onShare: (_) {},
      onExpandedExtentMeasured: (_) {},
    );
    expect(
      estimating.maxExtent,
      ReplicaProfileHeaderGeometry.initialExtentEstimate,
    );

    final measured = ReplicaProfileHeaderDelegate(
      user: sampleUser(42),
      isMe: true,
      selectedTabIndex: 0,
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
        builder: promptHostBuilder,
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
                      user: sampleUser(42),
                      isMe: true,
                      selectedTabIndex: 0,
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
        sampleUser(42).copyWith(
          profileImageUrl: 'https://i.pximg.net/avatar.png',
          backgroundImageUrl: 'https://i.pximg.net/background.png',
        ),
        sampleUser(42),
      ];
      for (final user in users) {
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            MaterialApp(
              builder: promptHostBuilder,
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
        builder: promptHostBuilder,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),

        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              _MeasuredProfileHeader(
                delegateFor: (extent, onMeasured) =>
                    ReplicaProfileHeaderDelegate(
                      user: sampleUser(42),
                      isMe: true,
                      selectedTabIndex: 0,
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
        builder: promptHostBuilder,
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
                      onShare: (_) {},
                      onEditProfile: () {},
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
    "the overflow lists the name row's actions once they scroll away",
    (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          builder: promptHostBuilder,
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
                        user: sampleUser(42),
                        isMe: true,
                        selectedTabIndex: 0,
                        onShare: (_) {},
                        onEditProfile: () {},
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
      // Each action shows once at a time: while the name row is on screen
      // the overflow leaves its share and main action out.
      Future<void> openMenu() async {
        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
      }

      Future<void> closeMenu() async {
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
      }

      await openMenu();
      expect(find.text('分享用户'), findsNothing);
      expect(find.text('编辑个人资料'), findsOneWidget);
      // The list filters sit over the lists now, not in the overflow.
      expect(find.text('公开'), findsNothing);
      expect(find.text('私密'), findsNothing);
      expect(find.text('收藏标签'), findsNothing);
      expect(find.text('下载全部作品'), findsOneWidget);
      await closeMenu();

      // The menu takes them over as soon as the row's top edge passes
      // under the toolbar and the buttons start to be cut off.
      const rowTop =
          ReplicaProfileHeaderGeometry.bannerBelowToolbar +
          ReplicaProfileHeaderGeometry.nameRowBelowBanner;
      controller.jumpTo(rowTop);
      await tester.pump();
      expect(
        tester.getRect(find.byTooltip('分享用户')).top,
        greaterThanOrEqualTo(
          tester.getRect(find.byIcon(Icons.more_vert)).bottom,
        ),
      );
      await openMenu();
      expect(find.text('分享用户'), findsNothing);
      await closeMenu();
      controller.jumpTo(rowTop + 1);
      await tester.pump();
      await openMenu();
      expect(find.text('分享用户'), findsOneWidget);
      // The cut-off inline button + the menu item.
      expect(find.text('编辑个人资料'), findsNWidgets(2));
      await closeMenu();

      controller.jumpTo(_headerCollapseRange(tester));
      await tester.pump();
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('分享用户'), findsOneWidget);
      // Collapsed: the inline identity is offstage, only the menu item.
      expect(find.text('编辑个人资料'), findsOneWidget);
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
              user: sampleUser(42),
              isMe: true,
              selectedTabIndex: 0,
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
        builder: promptHostBuilder,
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
      var copyCount = 0;
      final controller = ScrollController();
      Widget header() => Scaffold(
        body: CustomScrollView(
          controller: controller,
          slivers: [
            _MeasuredProfileHeader(
              delegateFor: (extent, onMeasured) => ReplicaProfileHeaderDelegate(
                user: sampleUser(42),
                isMe: true,
                selectedTabIndex: 0,
                onShare: (_) {},
                onCopyLink: () => copyCount++,
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
          builder: promptHostBuilder,
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
        await tester.tap(find.text('复制链接'));
        await tester.pumpAndSettle();
        expect(copyCount, 1, reason: 'progress $progress');
        copyCount = 0;

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
      final coverUser = sampleUser(
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
                onShare: (_) {},
                onCopyLink: () {},
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
            builder: promptHostBuilder,
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
              user: sampleUser(42),
              isMe: true,
              selectedTabIndex: 0,
              onShare: (_) {},
              onCopyLink: () {},
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
        builder: promptHostBuilder,
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
        builder: promptHostBuilder,
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
            sampleUser(
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

      await tester.pumpWidget(app(sampleUser(42)));
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
      final repository = FakeUserRepository(
        detailFailure: const ApiNetworkError('offline'),
      );
      final container = await makeProfileWorld(users: repository);
      container.read(userStoreProvider.notifier).mergeAll([sampleUser(42)]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: promptHostBuilder,
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

  testWidgets('work tabs follow the types a user has, with their counts', (
    tester,
  ) async {
    final repository = FakeUserRepository(
      detail: sampleUser(42).copyWith(
        totalIllusts: 12345,
        totalNovels: 3,
        totalNovelSeries: 2,
        hasDetail: true,
      ),
    );
    final container = await makeProfileWorld(users: repository);
    await _pumpProfile(tester, container);

    // Manga and series are empty, and novel series have no list of their
    // own: neither gets a tab.
    expect(_tabLabels(tester), ['插画 1.2万', '小说 3', '收藏', '关注', '关于']);
    // Another user's lists have no filters to offer.
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-filter-restrict')), findsNothing);
    await tester.tap(find.text('插画 1.2万'));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(repository.requests, contains('works:42:illust:first'));
    expect(find.byType(EasyRefresh), findsOneWidget);
    expect(find.byType(HeaderLocator), findsOneWidget);

    await tester.tap(find.text('小说 3'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileNovelFeed), findsOneWidget);
    expect(_selectedTabIndex(tester), 1);

    // Re-tapping a tab keeps it selected.
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(_selectedTabIndex(tester), 2);
  });

  testWidgets('own bookmarks and follows filter above the list', (
    tester,
  ) async {
    final users = FakeUserRepository(
      detail: sampleUser(100).copyWith(hasDetail: true),
    );
    final bookmarks = RecordingBookmarkRepository()
      ..tagPage = const UserBookmarkTagPage(
        tags: [
          UserBookmarkTag(name: 'cat', count: 3),
          UserBookmarkTag(name: 'dog', count: 1),
        ],
        nextUrl: null,
      );
    final container = await makeProfileWorld(
      users: users,
      bookmarks: bookmarks,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: promptHostBuilder,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: MePage(onEditProfile: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final restrictFilter = find.byKey(
      const ValueKey('profile-filter-restrict'),
    );
    final tagFilter = find.byKey(const ValueKey('profile-filter-tag'));
    Finder menuItem(String label) => find.descendant(
      of: find.byType(MenuItemButton),
      matching: find.text(label),
    );

    expect(_tabLabels(tester), ['收藏', '关注', '粉丝', '好P友']);
    expect(
      find.descendant(of: restrictFilter, matching: find.text('公开')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tagFilter, matching: find.text('标签：全部')),
      findsOneWidget,
    );
    expect(tester.getSize(tagFilter).height, greaterThanOrEqualTo(48));

    // Two tags fit the menu: no detour to the tag page.
    await tester.tap(tagFilter);
    await tester.pumpAndSettle();
    expect(menuItem('全部'), findsOneWidget);
    expect(menuItem('dog'), findsOneWidget);
    expect(menuItem('更多标签…'), findsNothing);
    await tester.tap(menuItem('cat'));
    await tester.pumpAndSettle();
    expect(users.requests, contains('bookmarks:100:public:cat'));
    expect(
      find.descendant(of: tagFilter, matching: find.text('标签：cat')),
      findsOneWidget,
    );

    // A visibility change clears the tag: tags are per visibility.
    await tester.tap(restrictFilter);
    await tester.pumpAndSettle();
    await tester.tap(menuItem('私密'));
    await tester.pumpAndSettle();
    expect(users.requests, contains('bookmarks:100:private:'));
    expect(
      find.descendant(of: tagFilter, matching: find.text('标签：全部')),
      findsOneWidget,
    );

    // Follows: the visibility filter alone, sharing the same value.
    await tester.tap(
      find.descendant(of: find.byType(TabBar), matching: find.text('关注')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: restrictFilter.hitTestable(),
        matching: find.text('私密'),
      ),
      findsOneWidget,
    );
    expect(tagFilter.hitTestable(), findsNothing);
  });

  testWidgets('a long tag list sends the rest to the tag page', (tester) async {
    final bookmarks = RecordingBookmarkRepository()
      ..tagPage = UserBookmarkTagPage(
        tags: [
          for (var i = 0; i < 11; i++)
            UserBookmarkTag(name: 'tag $i', count: 1),
        ],
        nextUrl: null,
      );
    final container = await makeProfileWorld(
      users: FakeUserRepository(
        detail: sampleUser(100).copyWith(hasDetail: true),
      ),
      bookmarks: bookmarks,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: promptHostBuilder,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: MePage(onEditProfile: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-filter-tag')));
    await tester.pumpAndSettle();
    Finder menuItem(String label) => find.descendant(
      of: find.byType(MenuItemButton),
      matching: find.text(label),
    );
    expect(menuItem('tag 9'), findsOneWidget);
    expect(menuItem('tag 10'), findsNothing);
    expect(menuItem('更多标签…'), findsOneWidget);
  });

  testWidgets('a profile without works opens on its first other tab', (
    tester,
  ) async {
    final repository = FakeUserRepository(
      detail: sampleUser(42).copyWith(hasDetail: true),
    );
    final container = await makeProfileWorld(users: repository);
    await _pumpProfile(tester, container);

    expect(_tabLabels(tester), ['收藏', '关注', '关于']);
    expect(_selectedTabIndex(tester), 0);
    expect(repository.requests, contains('bookmarks:42:public:'));
    expect(
      repository.requests.where((request) => request.startsWith('works:')),
      isEmpty,
    );
  });

  testWidgets('a tab that disappears on refresh falls back to the first', (
    tester,
  ) async {
    final repository = FakeUserRepository(
      detail: sampleUser(
        42,
      ).copyWith(totalIllusts: 2, totalManga: 2, hasDetail: true),
    );
    final container = await makeProfileWorld(users: repository);
    await _pumpProfile(tester, container);

    // A tab that survives the refresh stays selected.
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    repository.detail = repository.detail.copyWith(totalNovels: 1);
    await container.read(userDetailControllerProvider(42).notifier).reload();
    await tester.pumpAndSettle();
    expect(_tabLabels(tester), ['插画 2', '漫画 2', '小说 1', '收藏', '关注', '关于']);
    expect(_selectedTabIndex(tester), 3);

    // The selected tab is gone after the refresh: the first tab takes over.
    await tester.tap(find.text('漫画 2'));
    await tester.pumpAndSettle();
    repository.detail = repository.detail.copyWith(totalManga: 0);
    await container.read(userDetailControllerProvider(42).notifier).reload();
    await tester.pumpAndSettle();
    expect(_tabLabels(tester), ['插画 2', '小说 1', '收藏', '关注', '关于']);
    expect(_selectedTabIndex(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile stats open their tabs and keep myPixiv read-only', (
    tester,
  ) async {
    final repository = FakeUserRepository(
      detail: sampleUser(42).copyWith(
        totalFollowUsers: 11,
        totalMyPixivUsers: 12,
        totalIllusts: 13,
        totalManga: 14,
        totalNovels: 15,
        totalIllustSeries: 3,
        totalNovelSeries: 4,
        hasDetail: true,
      ),
    );
    final container = await makeProfileWorld(users: repository);
    await _pumpProfile(tester, container);
    expect(_tabLabels(tester), [
      '插画 13',
      '漫画 14',
      '小说 15',
      '系列 3',
      '收藏',
      '关注',
      '关于',
    ]);

    // The header line: following opens its tab; another user's My Pixiv
    // list has no tab, so that count is plain text.
    final followingStat = find.byKey(
      const ValueKey('profile-stat-following-header'),
    );
    expect(
      tester.getSemantics(followingStat),
      isSemantics(label: '11 关注', isButton: true, hasTapAction: true),
    );
    final myPixivStat = find.byKey(
      const ValueKey('profile-stat-myPixiv-header'),
    );
    expect(
      tester.getSemantics(myPixivStat),
      isSemantics(label: '12 好P友', isButton: false, hasTapAction: false),
    );
    expect(tester.getSize(followingStat).height, greaterThanOrEqualTo(48));
    await tester.tap(followingStat);
    await tester.pumpAndSettle();
    expect(_selectedTabIndex(tester), 5);

    // The about page lists every count; works open their tabs. The series
    // stat counts illust series only: that is what the series tab lists.
    Future<void> tapAboutStat(String id) async {
      await tester.tap(
        find.descendant(of: find.byType(TabBar), matching: find.text('关于')),
      );
      await tester.pumpAndSettle();
      // The stats close the about list, below the fold.
      final stat = find.byKey(
        ValueKey('profile-stat-$id-about'),
        skipOffstage: false,
      );
      await tester.ensureVisible(stat);
      await tester.pumpAndSettle();
      await tester.tap(stat);
      await tester.pumpAndSettle();
    }

    final aboutSeries = find.byKey(
      const ValueKey('profile-stat-series-about'),
      skipOffstage: false,
    );
    await tester.tap(
      find.descendant(of: find.byType(TabBar), matching: find.text('关于')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(aboutSeries);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(aboutSeries),
      isSemantics(label: '系列, 3', isButton: true, hasTapAction: true),
    );
    await tapAboutStat('series');
    expect(_selectedTabIndex(tester), 3);
    expect(find.byType(UserSeriesFeed), findsOneWidget);

    await tapAboutStat('following');
    expect(_selectedTabIndex(tester), 5);
    expect(repository.requests, contains('relation:42:following'));

    await tapAboutStat('manga');
    expect(_selectedTabIndex(tester), 1);
  });

  for (final isMe in [false, true]) {
    testWidgets('name, share and the main action share one row '
        '(320dp @ 1.3x, isMe=$isMe)', (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = FakeUserRepository(
        detail: sampleUser(42).copyWith(
          name: 'an extremely long display name that keeps going',
          totalFollowUsers: 1234,
          totalMyPixivUsers: 56,
          hasDetail: true,
        ),
      );
      final container = await makeProfileWorld(users: repository);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            builder: (context, child) => promptHostBuilder(
              context,
              MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.3)),
                child: child!,
              ),
            ),
            home: isMe
                ? MePage(onEditProfile: () {})
                : const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final nameFinder = find.byKey(const ValueKey('profile-expanded-name'));
      final name = tester.getRect(nameFinder);
      final share = tester.getRect(find.byIcon(Icons.share_outlined));
      final main = tester.getRect(
        isMe ? find.byType(FilledButton) : find.byType(FollowSwitchButton),
      );
      // The long name gives way: it ellipsizes before the buttons wrap.
      expect(
        tester.renderObject<RenderParagraph>(nameFinder).didExceedMaxLines,
        isTrue,
      );
      expect(name.right, lessThanOrEqualTo(share.left));
      expect(share.right, lessThanOrEqualTo(main.left));
      expect(main.right, lessThanOrEqualTo(320));
      // One row: the buttons sit level with the name block.
      expect(share.top, lessThan(name.bottom));
      expect(main.top, lessThan(name.bottom));
      expect(find.text('@sample'), findsOneWidget);
      // The statistics line sits under the row.
      final following = tester.getRect(
        find.byKey(const ValueKey('profile-stat-following-header')),
      );
      expect(following.top, greaterThanOrEqualTo(share.bottom - 0.5));
      expect(find.text('1234 关注'), findsOneWidget);
    });
  }

  testWidgets('the expanded header is measured from its content', (
    tester,
  ) async {
    const statIds = ['following', 'myPixiv'];
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
      final repository = FakeUserRepository(
        detail: sampleUser(42).copyWith(
          backgroundImageUrl: cover ? 'https://i.pximg.net/bg.png' : null,
          totalFollowUsers: 1234567,
          totalMyPixivUsers: 1234,
          hasDetail: true,
        ),
      );
      final container = await makeProfileWorld(users: repository);
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: locale,
              builder: (context, child) => promptHostBuilder(
                context,
                MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
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
    final repository = FakeUserRepository(
      detail: sampleUser(42).copyWith(account: 'sample'),
    );
    final container = await makeProfileWorld(users: repository);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          builder: (context, child) => promptHostBuilder(
            context,
            MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
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

    // The refreshed user brings its counters: the statistics line appears
    // (and wraps at 2x), which must grow the measured extent instead of
    // overflowing. The page reads the entity captured by
    // userDetailControllerProvider, so the refresh has to go through
    // reload() — a bare UserStore.mergeAll never reaches it.
    repository.detail = sampleUser(42).copyWith(
      name: 'an extremely long display name that keeps going',
      totalFollowUsers: 1234567,
      totalMyPixivUsers: 1234,
      hasDetail: true,
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
    for (final id in ['following', 'myPixiv']) {
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
    final repository = FakeUserRepository(
      works: List.generate(30, (index) => _illust(index + 1)),
    );
    final container = await makeProfileWorld(users: repository);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('ru'),
            builder: (context, child) => promptHostBuilder(
              context,
              MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
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
      // More steps back than forward: what the collapsed header did not
      // take went to the feed, which unwinds first.
      for (var step = 0; step < 20; step++) {
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
        final repository = FakeUserRepository(
          works: List.generate(30, (index) => _illust(index + 1)),
        );
        final container = await makeProfileWorld(users: repository);
        await mockNetworkImagesFor(() async {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                builder: promptHostBuilder,
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
      final repository = FakeUserRepository(
        works: List.generate(30, (index) => _illust(index + 1)),
      );
      final container = await makeProfileWorld(users: repository);
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              builder: promptHostBuilder,
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

  testWidgets('the tab strip shows the edge line over a scrolled feed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository = FakeUserRepository(
      works: List.generate(30, (index) => _illust(index + 1)),
    );
    final container = await makeProfileWorld(users: repository);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: promptHostBuilder,
            theme: replicaTheme(Brightness.light),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            scrollBehavior: const FuncScrollBehavior(),
            home: const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();

      bool edgeLine() => tester
          .widget<ScrollEdgeLine>(
            find.descendant(
              of: find.byKey(const ValueKey('profile-tabs')),
              matching: find.byType(ScrollEdgeLine),
            ),
          )
          .visible;
      Material strip() =>
          tester.widget<Material>(find.byKey(const ValueKey('profile-tabs')));
      expect(edgeLine(), isFalse);
      expect(
        strip().color,
        replicaTheme(Brightness.light).scaffoldBackgroundColor,
      );

      // Header collapsed but the feed at its top: nothing is under the strip.
      final outer = outerPosition(tester);
      outer.jumpTo(outer.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(edgeLine(), isFalse);

      final inner = activeFeedPosition(tester);
      inner.jumpTo(120);
      await tester.pumpAndSettle();
      expect(edgeLine(), isTrue);
      expect(
        strip().color,
        replicaTheme(Brightness.light).scaffoldBackgroundColor,
      );

      inner.jumpTo(0);
      await tester.pumpAndSettle();
      expect(edgeLine(), isFalse);
    });
  });

  testWidgets('a pull at the very top still pulls to refresh', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository = FakeUserRepository(
      works: List.generate(30, (index) => _illust(index + 1)),
    );
    final container = await makeProfileWorld(users: repository);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: promptHostBuilder,
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

  testWidgets('the banner without a cover is a container, not the page '
      'colour', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: promptHostBuilder,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              _MeasuredProfileHeader(
                delegateFor: (extent, onMeasured) =>
                    ReplicaProfileHeaderDelegate(
                      user: sampleUser(42),
                      isMe: true,
                      selectedTabIndex: 0,
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
      final repository = FakeUserRepository(
        works: List.generate(36, (index) => _illust(index + 1)),
      );
      final container = await makeProfileWorld(users: repository);
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              builder: promptHostBuilder,
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

        await tester.tap(
          find.descendant(of: find.byType(TabBar), matching: find.text('插画')),
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
      final repository = FakeUserRepository(
        works: List.generate(36, (index) => _illust(index + 1)),
        bookmarks: List.generate(36, (index) => _illust(100 + index)),
      );
      final container = await makeProfileWorld(users: repository);
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              builder: promptHostBuilder,
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

        // Scroll tab A (插画), then switch to tab B (收藏) — the TabBarView
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

  testWidgets('each work tab mounts its own feed', (tester) async {
    final repository = FakeUserRepository();
    final container = await makeProfileWorld(users: repository);
    await _pumpProfile(tester, container);
    Finder tab(String label) =>
        find.descendant(of: find.byType(TabBar), matching: find.text(label));

    // Without the detail counters every work type keeps its tab.
    expect(_tabLabels(tester).take(4), ['插画', '漫画', '小说', '系列']);
    expect(repository.requests, contains('works:42:illust:first'));

    await tester.tap(tab('漫画'));
    await tester.pumpAndSettle();
    expect(repository.requests, contains('works:42:manga:first'));

    await tester.tap(tab('小说'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileNovelFeed), findsOneWidget);

    await tester.tap(tab('系列'));
    await tester.pumpAndSettle();
    expect(find.byType(UserSeriesFeed), findsOneWidget);
  });

  testWidgets(
    'a pending profile shows the skeleton and the back button leaves',
    (tester) async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final repository = FakeUserRepository()..detailGate = gate;
      final container = await makeProfileWorld(users: repository);

      // Push the page so canPop is true — the skeleton's BackButton is a
      // real affordance, not a dead icon.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: promptHostBuilder,
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
        // A loaded profile has its counters, so the statistics line is
        // there for the skeleton's line to stand in for.
        final repository = FakeUserRepository(
          detail: sampleUser(
            42,
          ).copyWith(totalIllusts: 3, totalFollowUsers: 12, hasDetail: true),
        )..detailGate = gate;
        final container = await makeProfileWorld(users: repository);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh', 'CN'),
              builder: (context, child) => promptHostBuilder(
                context,
                MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
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
        for (var i = 0; i < 20; i++) {
          if (find.byType(ProfileSkeleton).evaluate().isEmpty) break;
          await tester.pump(const Duration(milliseconds: 1));
        }
        // The loaded profile replaces the skeleton and fades in.
        expect(find.byType(ProfileSkeleton), findsNothing);
        final fade = tester.widget<FadeTransition>(
          find
              .descendant(
                of: find.byType(StateFade),
                matching: find.byType(FadeTransition),
              )
              .first,
        );
        expect(fade.opacity.value, lessThan(1));
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
    final user = sampleUser(42).copyWith(
      webpage: 'https://example.test/portfolio',
      twitterUrl: 'https://social.test/sample',
      pawooUrl: 'https://pawoo.test/sample',
    );
    final container = await makeProfileWorld(
      users: FakeUserRepository(detail: user),
      outboundUrlOpener: opener,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: promptHostBuilder,
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
      final repository = FakeFollowRepository();
      final container = await makeProfileWorld(
        follows: repository,
        users: FakeUserRepository(),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: promptHostBuilder,
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
      // The shared follow sheet: direct actions, no confirm step.
      expect(find.widgetWithText(FilledButton, '公开关注'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, '私密关注'));
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
    final container = await makeProfileWorld(
      users: FakeUserRepository(),
      shareService: share,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: promptHostBuilder,
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
      required List<String> labels,
      double width = 411,
      double textScale = 1,
    }) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TabController(length: labels.length, vsync: tester);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: promptHostBuilder,
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
                      labels: labels,
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

    const ownZh = ['收藏', '关注', '粉丝', '好P友', '插画'];

    testWidgets('isMe zh labels share equal-width slots at natural size', (
      tester,
    ) async {
      await pumpTabs(tester, locale: const Locale('zh', 'CN'), labels: ownZh);
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
        labels: ownZh,
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
      await pumpTabs(
        tester,
        locale: const Locale('en'),
        labels: const ['Illustrations 12', 'Bookmarks', 'Following', 'About'],
      );
      final bar = tester.widget<TabBar>(find.byType(TabBar));
      expect(bar.isScrollable, isTrue);
      expect(bar.tabAlignment, TabAlignment.start);
      expect(labelFontSize(tester), labelSize);
    });
  });

  testWidgets(
    'header tabs and actions stay mounted while the work feed fails',
    (tester) async {
      final repository = FakeUserRepository(
        worksFailure: ApiNetworkError(StateError('offline')),
      );
      final container = await makeProfileWorld(users: repository);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: promptHostBuilder,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            home: const UserPage(userId: 42),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The work feed's first page request failed, but the query context —
      // the tabs and the header action row — stays mounted (parent §6 gate:
      // chrome survives loading/error/empty).
      expect(repository.requests, contains('works:42:illust:first'));
      expect(_tabLabels(tester).take(4), ['插画', '漫画', '小说', '系列']);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-expanded-name')),
        findsOneWidget,
      );
    },
  );

  testWidgets('tab labels stay on one line at 1.3x text scale', (tester) async {
    const labels = ['插画 1.2万', '漫画 3', '收藏', '关注', '关于'];
    final controller = TabController(length: labels.length, vsync: tester);
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: promptHostBuilder,
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
                    labels: labels,
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
    for (final label in labels) {
      final text = tester.widget<Text>(
        find.descendant(of: tabBar, matching: find.text(label)),
      );
      // The scrollable path leaves maxLines unset — null and 1 both
      // render single-line.
      expect(text.maxLines ?? 1, 1);
    }
  });
}

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
