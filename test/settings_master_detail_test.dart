import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/network/compat/network_providers.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/translation/translation_service.dart'
    show translationCredentialStoreProvider;
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/core/watchlater/watch_later_repository.dart';
import 'package:parfait/core/watchlater/watch_later_store.dart';
import 'package:parfait/features/settings/network_settings_page.dart';
import 'package:parfait/features/settings/settings_catalog.dart';
import 'package:parfait/features/settings/settings_helpers.dart';
import 'package:parfait/features/settings/settings_page.dart';
import 'package:parfait/l10n/app_localizations_zh.dart';

import 'helpers/api_responses.dart';
import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/memory_feed_snapshot_store.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';
import 'helpers/settings_world.dart';
import 'helpers/view_size.dart';

List<Override> _overrides() => [
  translationCredentialStoreProvider.overrideWithValue(FakeTranslationStore()),
  networkAccessPolicyProvider.overrideWithValue(stubNetworkPolicy()),
  ...accountProviderOverrides(
    credentialStore: FakeCredentialStore(
      values: const {'100': Credential(accessToken: 'a', refreshToken: 'r')},
    ),
  ),
];

void main() {
  final zh = AppLocalizationsZh();

  testWidgets(
    'wide desktop uses master-detail with nested navigation; below 840dp stays single column',
    (tester) async {
      setViewSize(tester, const Size(1280, 800));
      final router = pixivRouter(settingsIndexPath);
      await tester.pumpWidget(
        localizedRouterApp(
          router,
          overrides: _overrides(),
          builder: promptHostBuilder,
        ),
      );
      await tester.pumpAndSettle();

      // Master-detail mounts the initial detail page without a redundant back button.
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.byType(AccountSettingsPage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AccountSettingsPage),
          matching: find.byType(BackButton),
        ),
        findsNothing,
      );

      // Selecting Network swaps the detail pane without popping SettingsPage.
      final networkLabel = SettingsPageRef.network.title(zh);
      final networkRow = find.text(networkLabel);
      await tester.ensureVisible(networkRow);
      await tester.pump();
      await tester.tap(networkRow);
      await tester.pumpAndSettle();
      expect(find.byType(NetworkSettingsPage), findsOneWidget);
      expect(router.state.uri.path, settingsIndexPath);

      // Pushing a child inside the detail pane keeps SettingsPage mounted.
      final advancedLabel = SettingsPageRef.networkAdvanced.title(zh);
      await tester.scrollUntilVisible(
        find.text(advancedLabel),
        300,
        scrollable: find.descendant(
          of: find.byType(NetworkSettingsPage),
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text(advancedLabel));
      await tester.pumpAndSettle();
      expect(find.byType(NetworkAdvancedSettingsPage), findsOneWidget);
      final nestedBack = find.descendant(
        of: find.byType(NetworkAdvancedSettingsPage),
        matching: find.byType(BackButton),
      );
      expect(nestedBack, findsOneWidget);

      await tester.tap(nestedBack);
      await tester.pumpAndSettle();
      expect(find.byType(NetworkSettingsPage), findsOneWidget);
      expect(find.byType(SettingsPage), findsOneWidget);

      // Below 840dp content width falls back to the single-column index.
      setViewSize(tester, const Size(800, 8000));
      await tester.pump();
      expect(find.byType(NetworkSettingsPage), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'wide Me dashboard wraps SettingsDetailScope and opens bookmarks directly',
    (tester) async {
      setViewSize(tester, const Size(1280, 800));
      final router = pixivRouter('/settings');
      await tester.pumpWidget(
        localizedRouterApp(
          router,
          overrides: _overrides(),
          builder: promptHostBuilder,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('me-wide-dashboard')), findsOneWidget);
      final railList = find.byType(ListView).first;
      expect(find.text('个人资料'), findsNothing);
      for (final label in [
        zh.profileBookmarked,
        zh.profileFollowing,
        zh.watchlistTitle,
        zh.historySettings,
        zh.watchLaterTitle,
        zh.localNovelsTitle,
        zh.downloaderSettings,
      ]) {
        expect(
          find.descendant(of: railList, matching: find.text(label)),
          findsOneWidget,
        );
      }

      final detailNav = find.byType(Navigator).last;
      final detailHeader = find.descendant(
        of: find.byType(AppTopBar),
        matching: find.text(zh.profileBookmarked),
      );
      expect(detailHeader, findsOneWidget);
      expect(
        SettingsDetailScope.maybeOf(tester.element(detailHeader)),
        isNotNull,
      );

      await tester.tap(
        find.descendant(of: railList, matching: find.text(zh.historySettings)),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: detailNav,
          matching: find.descendant(
            of: find.byType(AppTopBar),
            matching: find.text(zh.historySettings),
          ),
        ),
        findsOneWidget,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  Future<(ProviderContainer, PixivApi)> makeMeWorld() async {
    final api = PixivApi({
      ...backgroundRoutes,
      ...shellRoutes,
      '/v1/user/detail': answer(
        userDetailJson(
          const UserEntity(id: 100, name: 'tester', account: 'tester'),
        ),
      ),
      '/v1/user/bookmarks/illust': answer(pageJson('illusts', const [])),
      '/v1/user/bookmark-tags/illust': answer({
        'bookmark_tags': const <Map<String, Object?>>[],
        'next_url': null,
      }),
    });
    final container = await signedInApiContainer(
      api.client,
      overrides: [
        feedSnapshotStoreProvider.overrideWithValue(MemoryFeedSnapshotStore()),
      ],
    );
    return (container, api);
  }

  testWidgets(
    'offstage Me dashboard defers profile and bookmark requests until visible',
    (tester) async {
      setViewSize(tester, const Size(1280, 800));
      final (container, api) = await makeMeWorld();
      final router = pixivRouter('/recommended');
      await tester.pumpWidget(
        localizedRouterApp(
          router,
          container: container,
          builder: promptHostBuilder,
        ),
      );
      await tester.pumpAndSettle();

      expect(api.sent('/v1/user/detail'), isEmpty);
      expect(api.sent('/v1/user/bookmarks/illust'), isEmpty);
      expect(api.sent('/v1/user/bookmark-tags/illust'), isEmpty);

      router.go('/settings');
      await tester.pumpAndSettle();

      expect(api.sent('/v1/user/detail'), hasLength(1));
      expect(api.sent('/v1/user/bookmarks/illust'), hasLength(1));
      expect(api.sent('/v1/user/bookmark-tags/illust'), hasLength(1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'wide settings prompts confirmDiscardDraft on category switch and outer pop for dirty root and child forms',
    (tester) async {
      await seedSettings(
        baseTestSettings().copyWith(
          namingRule: const NamingRule(
            preset: NamingPreset.custom,
            template: '{id}',
          ),
        ),
      );
      setViewSize(tester, const Size(1280, 1200));
      final router = pixivRouter('/recommended');
      await tester.pumpWidget(
        localizedRouterApp(
          router,
          overrides: _overrides(),
          builder: promptHostBuilder,
        ),
      );
      await tester.pumpAndSettle();
      unawaited(router.push('/settings/download'));
      await tester.pumpAndSettle();

      // Dirty the root DownloadSettingsPage custom template field.
      await tester.enterText(
        find.descendant(
          of: find.byType(DownloadSettingsPage),
          matching: find.byType(TextField),
        ),
        '{title}_{id}',
      );
      await tester.pumpAndSettle();

      // Category switch prompts; cancel keeps draft and page.
      await tester.tap(find.text(SettingsPageRef.about.title(zh)));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.byType(DownloadSettingsPage), findsOneWidget);

      // Outer pop also prompts; cancel stays, discard leaves SettingsPage.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);

      // Confirm category switch transitions cleanly to About.
      await tester.tap(find.text(SettingsPageRef.about.title(zh)));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutSettingsPage), findsOneWidget);

      // Dirty nested child (DownloadDestinationPage) also guards rail switch.
      await tester.tap(find.text(SettingsPageRef.download.title(zh)));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(DownloadSettingsPage),
          matching: find.text(SettingsPageRef.downloadDestination.title(zh)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(DownloadDestinationPage),
          matching: find.byType(TextField),
        ),
        'MyAlbum',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(SettingsPageRef.about.title(zh)));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutSettingsPage), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'wide Me dashboard forwards back to exit WatchLater managing mode before popping Me',
    (tester) async {
      final (container, _) = await makeMeWorld();
      await container.read(watchLaterRepositoryProvider).restoreAll('100', [
        WatchLaterEntry(addedAt: 1000, entity: parseIllust(illustJson(77))),
      ]);
      setViewSize(tester, const Size(1280, 800));
      final router = pixivRouter('/recommended');
      await tester.pumpWidget(
        localizedRouterApp(
          router,
          container: container,
          builder: promptHostBuilder,
        ),
      );
      await tester.pumpAndSettle();
      router.go('/settings');
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byType(ListView).first,
          matching: find.text(zh.watchLaterTitle),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, zh.manage));
      await tester.pumpAndSettle();
      expect(find.byTooltip(zh.selectAll), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byTooltip(zh.selectAll), findsNothing);
      expect(router.state.uri.path, '/settings');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/recommended');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
