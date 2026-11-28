import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/icons/ui_icons.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/platform/android_intent_channel.dart';
import 'package:parfait/core/user/follow_actions.dart';
import 'package:parfait/core/user/follow_store.dart';
import 'package:parfait/core/user/user_detail_controller.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/core/user/user_store.dart';
import 'package:parfait/features/profile/profile_header_delegate.dart';
import 'package:parfait/features/profile/profile_novel_feed.dart';
import 'package:parfait/features/profile/profile_skeleton.dart';
import 'package:parfait/features/profile/user_page.dart';

import 'helpers/api_responses.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/profile_world.dart';
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

  @override
  Widget build(BuildContext context) {
    final delegate = widget.delegateFor(_extent, (extent) {
      if (_extent == null || (extent - _extent!).abs() > 0.5) {
        setState(() => _extent = extent);
      }
    });
    return SliverPersistentHeader(pinned: true, delegate: delegate);
  }
}

Future<void> _pumpProfile(
  WidgetTester tester,
  ProviderContainer container, {
  int userId = 42,
}) async {
  await tester.pumpWidget(
    localizedApp(
      container: container,
      builder: promptHostBuilder,
      home: UserPage(userId: userId),
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
      final repository = FollowApi()..gate = gate;
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
      final repository = FollowApi()..failure = failing(400);
      final container = await makeProfileWorld(follows: repository);
      final userStore = container.read(userStoreProvider.notifier);
      userStore.mergeAll([sampleUser(42)]);

      await container.read(followActionsProvider).toggle(42);
      final entry = container.read(followStoreProvider)[42]!;
      expect(entry.followed, isFalse);
      expect(entry.isPending, isFalse);
      expect(entry.error, isA<ApiHttpError>());
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
    expect(container.read(followStoreProvider)[301], isNull);

    container.read(userStoreProvider.notifier).mergeAll(users);
    expect(writes, 1, reason: 'an unchanged page must not notify');
  });

  testWidgets("someone else's overflow mutes them, then offers the unmute", (
    tester,
  ) async {
    var muted = false;
    Widget app() => localizedApp(
      builder: promptHostBuilder,
      body: CustomScrollView(
        slivers: [
          _MeasuredProfileHeader(
            delegateFor: (extent, onMeasured) => ReplicaProfileHeaderDelegate(
              user: sampleUser(42),
              isMe: false,
              selectedTabIndex: 0,
              onShare: (_) {},
              isMuted: muted,
              onToggleMute: () => muted = !muted,
              expandedExtent: extent,
              onExpandedExtentMeasured: onMeasured,
            ),
          ),
        ],
      ),
    );
    Future<void> openMenu() async {
      await tester.tap(find.byIcon(UiIcons.more));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(app());
    await tester.pump();
    await openMenu();
    await tester.tap(find.text('屏蔽作者'));
    await tester.pumpAndSettle();
    expect(muted, isTrue);

    await tester.pumpWidget(app());
    await openMenu();
    expect(find.text('解除屏蔽作者'), findsOneWidget);
  });

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
      localizedApp(
        builder: promptHostBuilder,
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
    expect(find.byType(BackButtonIcon), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(BackButtonIcon), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(BackButtonIcon), findsNothing);
  });

  testWidgets(
    'stale profile error banner can be dismissed without hiding the snapshot',
    (tester) async {
      final repository = UserApi(detailFailure: offline);
      final container = await makeProfileWorld(users: repository);
      container.read(userStoreProvider.notifier).mergeAll([sampleUser(42)]);
      await _pumpProfile(tester, container);

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

  testWidgets('work tabs follow the types a user has; each list shows its '
      'total', (tester) async {
    final repository = UserApi(
      detail: sampleUser(42).copyWith(
        totalIllusts: 12345,
        totalNovels: 3,
        totalNovelSeries: 2,
        hasDetail: true,
      ),
      works: [_illust(1)],
    );
    final novels = answer(pageJson('novels', [novelJson(1)]));
    final container = await makeProfileWorld(
      users: repository,
      routes: {'/v1/user/novels': novels},
    );
    await _pumpProfile(tester, container);

    expect(_tabLabels(tester), ['插画', '小说', '收藏', '关注', '关于']);
    expect(find.text('共 1.2万 件'), findsOneWidget);
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-filter-restrict')), findsNothing);
    expect(find.byKey(const ValueKey('profile-filter-tag')), findsNothing);
    expect(find.textContaining('共 '), findsNothing);
    await pickFilterMenu(tester, 'profile-filter-kind', '小说');
    expect(repository.requests, contains('novel-bookmarks:42:public:'));
    expect(find.byType(ProfileNovelFeed), findsOneWidget);
    await tester.tap(find.text('插画'));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(repository.requests, contains('works:42:illust:first'));
    expect(find.byType(EasyRefresh), findsOneWidget);

    await tester.tap(find.text('小说'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileNovelFeed), findsOneWidget);
    expect(find.text('共 3 件'), findsOneWidget);
    expect(_selectedTabIndex(tester), 1);
  });

  testWidgets('a profile without works opens on its first other tab', (
    tester,
  ) async {
    final repository = UserApi(
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
    final repository = UserApi(
      detail: sampleUser(
        42,
      ).copyWith(totalIllusts: 2, totalManga: 2, hasDetail: true),
    );
    final container = await makeProfileWorld(users: repository);
    await _pumpProfile(tester, container);

    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    repository.detail = repository.detail.copyWith(totalNovels: 1);
    await container.read(userDetailControllerProvider(42).notifier).reload();
    await tester.pumpAndSettle();
    expect(_tabLabels(tester), ['插画', '漫画', '小说', '收藏', '关注', '关于']);
    expect(_selectedTabIndex(tester), 3);

    await tester.tap(find.text('漫画'));
    await tester.pumpAndSettle();
    repository.detail = repository.detail.copyWith(totalManga: 0);
    await container.read(userDetailControllerProvider(42).notifier).reload();
    await tester.pumpAndSettle();
    expect(_tabLabels(tester), ['插画', '小说', '收藏', '关注', '关于']);
    expect(_selectedTabIndex(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a pending profile shows the skeleton and the back button leaves',
    (tester) async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final repository = UserApi()..detailGate = gate;
      final container = await makeProfileWorld(users: repository);

      await tester.pumpWidget(
        localizedApp(
          container: container,
          builder: promptHostBuilder,
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
      users: UserApi(detail: user),
      outboundUrlOpener: opener,
    );
    await _pumpProfile(tester, container);
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
}

Map<String, dynamic> _illust(int id) => illustJson(id, width: 300, height: 400);

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
