import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/icons/ui_icons.dart';
import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/navigation/route_facade.dart';
import 'package:parfait/app/widgets/author_row.dart';
import 'package:parfait/app/widgets/feed/feed_selection.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/novel_entry.dart';
import 'package:parfait/app/widgets/tag_chips.dart';
import 'package:parfait/app/window/desktop_close_dispatcher.dart';
import 'package:parfait/app/window/desktop_menu_bar.dart';
import 'package:parfait/app/window/desktop_workspace_tabs.dart';
import 'package:parfait/core/mute/mute_models.dart';
import 'package:parfait/core/mute/mute_store.dart';
import 'package:parfait/core/navigation/home_destination.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/profile/user_page.dart';
import 'package:parfait/features/settings/pages/download_tasks_page.dart';
import 'package:parfait/l10n/app_localizations.dart';

import '../helpers/illust_fixtures.dart';
import '../helpers/leak_tracking.dart';
import '../review/review_support.dart';
import 'e2e_harness.dart';

Map<String, dynamic> _user(int id, String role) => {
  'id': id,
  'name': '$role $id',
  'account': 'u$id',
  'profile_image_urls': {'medium': 'https://i.pximg.net/u$id.jpg'},
};

Map<String, dynamic> _illustJson(int id, int userId, String title) =>
    reviewIllustJson(id)
      ..['title'] = title
      ..['user'] = _user(userId, 'Author');

Map<String, dynamic> _novelJson(int id, int userId, String title) =>
    reviewNovelJson(id)
      ..['title'] = title
      ..['user'] = _user(userId, 'Writer');

void main() {
  ignoreOctoImageFades();
  final desktop = reviewDevices['desktop']!;

  group('Desktop workspace tabs real-shell E2E', () {
    testWidgets(
      'DesktopWorkspaceTabStrip auto-hides at 1 tab, preserves scroll, cycles, inherits GoRouter, and closes on middle-click',
      (tester) async {
        await runE2eScene(
          tester,
          device: desktop,
          locale: const Locale('en'),
          body: (world, router) async {
            final tabs = DesktopWorkspaceTabsController.active!;
            final strip = find.byKey(const Key('desktop-workspace-tab-strip'));
            expect(tester.getSize(strip).height, 0);

            final scroll = tester
                .stateList<ScrollableState>(find.byType(Scrollable))
                .firstWhere(
                  (s) =>
                      s.position.axis == Axis.vertical &&
                      s.position.maxScrollExtent >= 240,
                );
            scroll.position.jumpTo(240);
            await tester.pump();
            expect(scroll.position.pixels, 240);

            final first = tabs.openTargetInBackground(
              IllustTabTarget(parseIllust(_illustJson(1000, 10, 'Sunset'))),
            );
            final duplicate = tabs.openTargetInBackground(
              IllustTabTarget(parseIllust(_illustJson(1000, 10, 'Sunset'))),
            );
            final second = tabs.openTargetInBackground(
              const UserTabTarget(userId: 99, name: 'Kuro'),
            );
            await settle(tester);

            expect(identical(first, duplicate), isTrue);
            expect(tabs.tabCount, 3);
            expect(tabs.activeIndex, 0);
            expect(scroll.position.pixels, 240);
            expect(
              tester.getSize(strip).height,
              kDesktopWorkspaceTabStripHeight,
            );

            tabs.cycleTab(delta: 1);
            await settle(tester);
            expect(tabs.activeIndex, 1);
            expect(find.byType(IllustDetailPage), findsOneWidget);
            expect(GoRouter.of(tabs.activeSecondaryContext!), same(router));

            tabs.cycleTab(delta: 1);
            await settle(tester);
            expect(tabs.activeIndex, 2);
            expect(find.byType(UserPage), findsOneWidget);

            for (final (delta, expected) in const [(1, 0), (-1, 2), (-1, 1)]) {
              tabs.cycleTab(delta: delta);
              await settle(tester, 1);
              expect(tabs.activeIndex, expected);
            }

            await middleClick(
              tester,
              find.byKey(Key('desktop-workspace-tab-${second!.id}')),
            );
            expect(tabs.tabCount, 2);

            await tapAndSettle(
              tester,
              find.descendant(
                of: find.byKey(Key('desktop-workspace-tab-${first!.id}')),
                matching: find.byIcon(UiIcons.close),
              ),
            );
            expect(tabs.tabCount, 1);
            expect(tabs.activeIndex, 0);
            expect(scroll.position.pixels, 240);
            expect(tester.getSize(strip).height, 0);
          },
        );
      },
    );

    testWidgets(
      'Middle-click opens background tabs while preserving muted safety and Ctrl+Click batch selection',
      (tester) async {
        final cleanArt = _illustJson(1000, 10, 'Clean Art');
        final mutedArt = _illustJson(1001, 88, 'Muted Art');
        final cleanNovel = _novelJson(2000, 20, 'Clean Novel');
        final mutedNovel = _novelJson(2001, 88, 'Muted Novel');
        Finder card(int id) =>
            find.byWidgetPredicate((w) => w is IllustCard && w.entity.id == id);
        Finder novel(int id) =>
            find.byWidgetPredicate((w) => w is NovelEntry && w.entity.id == id);

        await runE2eScene(
          tester,
          device: desktop,
          locale: const Locale('en'),
          api: {
            '/v1/illust/recommended': reviewJson({
              'illusts': [cleanArt, mutedArt],
              'next_url': null,
            }),
            '/v1/novel/recommended': reviewJson({
              'novels': [cleanNovel, mutedNovel],
              'next_url': null,
            }),
            '/v1/illust/detail': reviewJson({'illust': cleanArt}),
          },
          overrides: [
            effectiveMutesProvider.overrideWithValue(
              const MuteFilterSnapshot(
                users: {88: MutedUser(userId: 88, name: 'Muted')},
              ),
            ),
          ],
          body: (world, router) async {
            final tabs = DesktopWorkspaceTabsController.active!;
            await middleClick(tester, card(1000));
            await middleClick(tester, card(1001));
            expect(tabs.secondaryTabs.map((t) => t.dedupeKey), ['illust:1000']);

            final selection = FeedSelectionScope.maybeOf(
              tester.element(card(1000)),
            )!;
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.tap(card(1000));
            await tester.pump();
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            await tester.pump();
            expect(selection.isSelected(1000), isTrue);
            expect(selection.selectedCount, 1);
            expect(tabs.secondaryTabs, hasLength(1));
            selection.clearSelection();
            await tester.pump();

            await tapAndSettle(tester, find.text('Novel'));
            await middleClick(tester, novel(2000));
            await middleClick(tester, novel(2001));
            expect(tabs.secondaryTabs.map((t) => t.dedupeKey), [
              'illust:1000',
              'novel:2000',
            ]);

            router.go('/recommended/novel-series/77');
            await settle(tester);
            await middleClick(tester, find.byType(AuthorRow).first);

            tabs.selectTab(1);
            await settle(tester);
            await middleClick(tester, find.byType(TagChip).first);

            final keys = tabs.secondaryTabs.map((t) => t.dedupeKey).toList();
            expect(keys.take(3), ['illust:1000', 'novel:2000', 'user:99']);
            expect(keys, hasLength(4));
            expect(keys.last, startsWith('search:'));
          },
        );
      },
    );

    testWidgets(
      'Layered Cmd+W and Ctrl+W dismiss overlays, inspector, secondary tab, then macOS window only',
      (tester) async {
        await runE2eScene(
          tester,
          device: desktop,
          locale: const Locale('en'),
          body: (world, router) async {
            final tabs = DesktopWorkspaceTabsController.active!;
            final l10n = AppLocalizations.of(
              tester.element(find.byType(DesktopWorkspaceTabStrip)),
            );

            var inspectorOpen = true;
            bool dismissInspector() {
              if (!inspectorOpen) return false;
              inspectorOpen = false;
              DesktopInspectorDismissRegistry.unregister(dismissInspector);
              return true;
            }

            DesktopInspectorDismissRegistry.register(dismissInspector);
            addTearDown(
              () =>
                  DesktopInspectorDismissRegistry.unregister(dismissInspector),
            );

            tabs.openBackgroundTab(
              title: 'Tab 1',
              icon: AppIcons.illust,
              builder: (_) => const Scaffold(body: Text('Secondary Page')),
            );
            tabs.selectTab(1);
            await settle(tester, 1);

            bool hasFileMenuLabel(String label) =>
                buildDesktopPlatformMenus(
                      l10n: l10n,
                      router: router,
                      isFullScreen: false,
                      destinations: HomeDestination.values,
                    )
                    .whereType<PlatformMenu>()
                    .elementAt(1)
                    .menus
                    .whereType<PlatformMenuItemGroup>()
                    .expand((g) => g.members)
                    .any((m) => m.label == label);

            expect(hasFileMenuLabel(l10n.windowCloseTab), isTrue);

            showDialog<void>(
              context: tabs.activeSecondaryContext!,
              builder: (_) => const AlertDialog(content: Text('Active Modal')),
            );
            await settle(tester, 1);
            expect(find.text('Active Modal'), findsOneWidget);

            var windowClosed = 0;
            bool close({required bool isMacOS}) => dispatchLayeredDesktopClose(
              router: router,
              isMacOS: isMacOS,
              onCloseWindow: () => windowClosed += 1,
            );

            expect(close(isMacOS: false), isTrue);
            await settle(tester, 1);
            expect(find.text('Active Modal'), findsNothing);
            expect(inspectorOpen, isTrue);
            expect(tabs.isOnSecondaryTab, isTrue);

            expect(close(isMacOS: false), isTrue);
            await settle(tester, 1);
            expect(inspectorOpen, isFalse);
            expect(tabs.isOnSecondaryTab, isTrue);

            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            await settle(tester, 1);
            expect(tabs.tabCount, 1);
            expect(tabs.activeIndex, 0);
            expect(hasFileMenuLabel(l10n.windowClose), isTrue);

            expect(close(isMacOS: false), isFalse);
            expect(windowClosed, 0);
            expect(close(isMacOS: true), isTrue);
            expect(windowClosed, 1);
          },
        );
      },
    );

    testWidgets(
      'Secondary tab switches unfocus root editor, isolate mouse back, skip hidden inspector, dedupe search filters, and focus root on GoRouter navigation',
      (tester) async {
        expect(
          const SearchTabTarget(IllustSearchQuery(keyword: 'cat')).dedupeKey,
          isNot(
            const SearchTabTarget(
              IllustSearchQuery(
                keyword: 'cat',
                filters: IllustSearchFilters(sort: SearchSort.popularDesc),
              ),
            ).dedupeKey,
          ),
        );

        await runE2eScene(
          tester,
          device: desktop,
          location: '/settings/all',
          locale: const Locale('en'),
          body: (world, router) async {
            final tabs = DesktopWorkspaceTabsController.active!;
            tabs.openBackgroundTab(
              title: 'Secondary',
              icon: UiIcons.chevronRight,
              builder: (_) => const Scaffold(body: Text('Secondary Root')),
            );
            await settle(tester, 1);

            await tester.tap(find.byType(SearchBar).first);
            await tester.pump();
            expect(isTextEditingFocused(), isTrue);

            tabs.selectTab(1);
            await settle(tester, 1);
            expect(isTextEditingFocused(), isFalse);

            final rootUriBefore = router.routerDelegate.currentConfiguration.uri
                .toString();
            Navigator.of(tabs.activeSecondaryContext!).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Secondary Pushed')),
              ),
            );
            await settle(tester, 1);
            expect(find.text('Secondary Pushed'), findsOneWidget);

            await mouseClick(
              tester,
              const Offset(400, 400),
              buttons: kBackMouseButton,
              settleSeconds: 1,
            );
            expect(find.text('Secondary Pushed'), findsNothing);
            expect(find.text('Secondary Root'), findsOneWidget);
            expect(
              router.routerDelegate.currentConfiguration.uri.toString(),
              rootUriBefore,
            );

            var offstageDismissed = false;
            bool dismissHidden() => offstageDismissed = true;
            DesktopInspectorDismissRegistry.register(
              dismissHidden,
              isActive: () => false,
            );
            addTearDown(
              () => DesktopInspectorDismissRegistry.unregister(dismissHidden),
            );
            expect(DesktopInspectorDismissRegistry.hasActive, isFalse);

            openDownloadsFromRouter(router, rail: false);
            await settle(tester);
            expect(tabs.activeIndex, 0);
            expect(find.byType(DownloadTasksPage), findsOneWidget);

            tabs.selectTab(1);
            await settle(tester, 1);
            expect(
              dispatchLayeredDesktopClose(router: router, isMacOS: false),
              isTrue,
            );
            expect(offstageDismissed, isFalse);
            expect(tabs.tabCount, 1);
            expect(tabs.activeIndex, 0);
          },
        );
      },
    );
  });
}
