import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kBackMouseButton, kMiddleMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/icons/ui_icons.dart';
import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/navigation/keyboard_back.dart';
import 'package:parfait/app/navigation/route_facade.dart';
import 'package:parfait/app/widgets/author_row.dart';
import 'package:parfait/app/widgets/feed/feed_selection.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/novel_entry.dart';
import 'package:parfait/app/widgets/tag_chips.dart';
import 'package:parfait/app/window/desktop_close_dispatcher.dart';
import 'package:parfait/app/window/desktop_menu_bar.dart';
import 'package:parfait/app/window/desktop_workspace_tabs.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/mute/mute_models.dart';
import 'package:parfait/core/mute/mute_store.dart';
import 'package:parfait/core/navigation/home_destination.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';

IllustEntity _illust(int id, {int userId = 10, String title = 'Work'}) {
  final raw = illustJson(id)
    ..['title'] = title
    ..['user'] = {
      'id': userId,
      'name': 'Author $userId',
      'account': 'a$userId',
      'profile_image_urls': {'medium': 'https://i.pximg.net/u.jpg'},
    };
  return parseIllust(raw);
}

NovelEntity _novel(int id, {int userId = 20, String title = 'Story'}) {
  final raw = novelJson(id, title: title)
    ..['user'] = {
      'id': userId,
      'name': 'Writer $userId',
      'account': 'w$userId',
      'profile_image_urls': {'medium': 'https://i.pximg.net/u.png'},
    };
  return NovelEntity.fromJson(raw);
}

Future<void> _middleClick(WidgetTester tester, Finder target) async {
  final center = tester.getCenter(target);
  final gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    buttons: kMiddleMouseButton,
  );
  await gesture.addPointer(location: center);
  try {
    await gesture.down(center);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  } finally {
    await gesture.removePointer();
    await tester.pump();
  }
}

void main() {
  testWidgets(
    'DesktopWorkspaceTabStrip auto-hides at 1 tab, preserves scroll, cycles, and closes on middle-click',
    (tester) async {
      final openedTargets = <DesktopTabTarget>[];
      final tabs = DesktopWorkspaceTabsController(
        pageBuilder: (target) {
          openedTargets.add(target);
          return (_) => Center(child: Text('Tab:${target.dedupeKey}'));
        },
      );
      addTearDown(tabs.dispose);

      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(
        localizedApp(
          locale: const Locale('en'),
          home: DesktopWorkspaceTabsScope(
            controller: tabs,
            child: Scaffold(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DesktopWorkspaceTabStrip(controller: tabs),
                  Expanded(
                    child: DesktopWorkspaceTabHost(
                      controller: tabs,
                      rootChild: ListView.builder(
                        controller: scrollController,
                        itemExtent: 60,
                        itemCount: 40,
                        itemBuilder: (_, i) => Text('Feed item $i'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Auto-hidden at 0dp when only the root tab exists.
      expect(
        tester
            .getSize(find.byKey(const Key('desktop-workspace-tab-strip')))
            .height,
        0,
      );

      scrollController.jumpTo(240);
      await tester.pump();
      expect(scrollController.offset, 240);

      // Opening background tabs expands strip to 36dp without leaving tab 0
      // or disturbing scroll offset; duplicate dedupeKey reuses existing tab.
      final first = tabs.openTargetInBackground(
        IllustTabTarget(_illust(101, title: 'Sunset')),
      );
      final duplicate = tabs.openTargetInBackground(
        IllustTabTarget(_illust(101, title: 'Sunset')),
      );
      final second = tabs.openTargetInBackground(
        const UserTabTarget(userId: 7, name: 'Kuro'),
      );
      await tester.pumpAndSettle();

      expect(identical(first, duplicate), isTrue);
      expect(tabs.tabCount, 3);
      expect(tabs.activeIndex, 0);
      expect(scrollController.offset, 240);
      expect(
        tester
            .getSize(find.byKey(const Key('desktop-workspace-tab-strip')))
            .height,
        kDesktopWorkspaceTabStripHeight,
      );
      expect(openedTargets.length, 2);

      // Cycling wraps cleanly across root -> tab1 -> tab2 -> root.
      tabs.cycleTab(delta: 1);
      await tester.pumpAndSettle();
      expect(tabs.activeIndex, 1);
      expect(find.text('Tab:illust:101'), findsOneWidget);

      tabs.cycleTab(delta: 1);
      await tester.pumpAndSettle();
      expect(tabs.activeIndex, 2);
      expect(find.text('Tab:user:7'), findsOneWidget);

      tabs.cycleTab(delta: -1);
      await tester.pumpAndSettle();
      expect(tabs.activeIndex, 1);

      // Middle-click closes secondary tab 2.
      await _middleClick(
        tester,
        find.byKey(Key('desktop-workspace-tab-${second!.id}')),
      );
      expect(tabs.tabCount, 2);

      // Clicking close button on remaining secondary tab collapses strip to 0dp
      // and restores the root feed at its untouched scroll offset.
      await tester.tap(find.byIcon(UiIcons.close).first);
      await tester.pumpAndSettle();
      expect(tabs.tabCount, 1);
      expect(tabs.activeIndex, 0);
      expect(scrollController.offset, 240);
      expect(
        tester
            .getSize(find.byKey(const Key('desktop-workspace-tab-strip')))
            .height,
        0,
      );
    },
  );

  testWidgets(
    'Middle-click opens background tabs while preserving muted safety and Ctrl+Click batch selection',
    (tester) async {
      final opened = <DesktopTabTarget>[];
      final tabs = DesktopWorkspaceTabsController(
        pageBuilder: (target) {
          opened.add(target);
          return (_) => const SizedBox.shrink();
        },
      );
      addTearDown(tabs.dispose);

      final unmutedIllust = _illust(1, userId: 10, title: 'Clean Art');
      final mutedIllust = _illust(2, userId: 99, title: 'Muted Art');
      final unmutedNovel = _novel(11, userId: 20, title: 'Clean Novel');
      final mutedNovel = _novel(12, userId: 99, title: 'Muted Novel');

      final selection = FeedSelectionController()
        ..syncEnabledFromLayout(true)
        ..syncItems([unmutedIllust, mutedIllust]);
      addTearDown(selection.dispose);

      var tagMiddleClicks = 0;

      await tester.pumpWidget(
        localizedApp(
          locale: const Locale('en'),
          overrides: [
            effectiveMutesProvider.overrideWithValue(
              const MuteFilterSnapshot(
                users: {99: MutedUser(userId: 99, name: 'Muted')},
              ),
            ),
          ],
          home: InputModalityScope(
            initialModality: InputModality.pointer,
            child: DesktopWorkspaceTabsScope(
              controller: tabs,
              child: FeedSelectionScope(
                controller: selection,
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 180,
                          child: IllustCard(
                            key: const Key('unmuted-illust'),
                            entity: unmutedIllust,
                          ),
                        ),
                        SizedBox(
                          width: 180,
                          child: IllustCard(
                            key: const Key('muted-illust'),
                            entity: mutedIllust,
                          ),
                        ),
                        NovelEntry.compact(
                          key: const Key('unmuted-novel'),
                          entity: unmutedNovel,
                        ),
                        NovelEntry.compact(
                          key: const Key('muted-novel'),
                          entity: mutedNovel,
                        ),
                        const AuthorRow(
                          key: Key('author-row'),
                          userId: 55,
                          name: 'Artist 55',
                        ),
                        TagChip(
                          key: const Key('tag-chip'),
                          label: 'landscape',
                          onTap: () {},
                          onMiddleClick: () => tagMiddleClicks += 1,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _middleClick(tester, find.byKey(const Key('unmuted-illust')));
      await _middleClick(tester, find.byKey(const Key('muted-illust')));
      await _middleClick(tester, find.byKey(const Key('unmuted-novel')));
      await _middleClick(tester, find.byKey(const Key('muted-novel')));
      await tester.ensureVisible(find.byKey(const Key('author-row')));
      await tester.pumpAndSettle();
      await _middleClick(tester, find.byKey(const Key('author-row')));
      await tester.ensureVisible(find.byKey(const Key('tag-chip')));
      await tester.pumpAndSettle();
      await _middleClick(tester, find.byKey(const Key('tag-chip')));

      expect(opened.map((t) => t.dedupeKey).toList(), [
        'illust:1',
        'novel:11',
        'user:55',
      ]);
      expect(tagMiddleClicks, 1);

      // Ctrl+Click still toggles FEED-24 batch selection without opening a tab.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.byKey(const Key('unmuted-illust')));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(selection.isSelected(1), isTrue);
      expect(selection.selectedCount, 1);
      expect(opened.length, 3);
    },
  );

  testWidgets(
    'Layered Cmd+W and Ctrl+W dismiss overlays, inspector, secondary tab, then macOS window only',
    (tester) async {
      final tabs = DesktopWorkspaceTabsController(
        pageBuilder: (_) =>
            (_) => const Text('Secondary Page'),
      )..attachAsActive();
      addTearDown(() {
        tabs.detachIfActive();
        tabs.dispose();
      });

      final router = GoRouter(
        initialLocation: '/recommended',
        routes: [
          GoRoute(
            path: '/recommended',
            builder: (_, _) => const Scaffold(body: Text('Root Workspace')),
          ),
        ],
      );
      addTearDown(router.dispose);

      var inspectorOpen = true;
      bool dismissInspector() {
        if (!inspectorOpen) return false;
        inspectorOpen = false;
        DesktopInspectorDismissRegistry.unregister(dismissInspector);
        return true;
      }

      DesktopInspectorDismissRegistry.register(dismissInspector);
      addTearDown(
        () => DesktopInspectorDismissRegistry.unregister(dismissInspector),
      );

      tabs.openBackgroundTab(
        title: 'Tab 1',
        icon: UiIcons.chevronRight,
        builder: (_) => const Scaffold(body: Text('Secondary Page')),
      );
      tabs.selectTab(1);

      late AppLocalizations l10n;
      await tester.pumpWidget(
        localizedRouterApp(
          router,
          locale: const Locale('en'),
          builder: (context, child) {
            l10n = AppLocalizations.of(context);
            return DesktopWorkspaceTabsScope(
              controller: tabs,
              child: KeyboardBack(
                router: router,
                destinations: HomeDestination.values,
                child: DesktopWorkspaceTabHost(
                  controller: tabs,
                  rootChild: child!,
                ),
              ),
            );
          },
        ),
      );
      await tester.pumpAndSettle();

      // macOS File menu dynamically labels "Close Tab" on a secondary tab.
      var menus = buildDesktopPlatformMenus(
        l10n: l10n,
        router: router,
        isFullScreen: false,
        destinations: HomeDestination.values,
      );
      final fileMenusSecondary = menus
          .whereType<PlatformMenu>()
          .elementAt(1)
          .menus
          .whereType<PlatformMenuItemGroup>()
          .expand((g) => g.members)
          .toList();
      expect(
        fileMenusSecondary.any((m) => m.label == l10n.windowCloseTab),
        isTrue,
      );

      // 1. Open a modal on the active secondary tab -> layered close pops modal first.
      final secondaryContext = tabs.activeSecondaryContext!;
      showDialog<void>(
        context: secondaryContext,
        builder: (_) => const AlertDialog(content: Text('Active Modal')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Active Modal'), findsOneWidget);

      var windowClosed = 0;
      expect(
        dispatchLayeredDesktopClose(
          router: router,
          isMacOS: false,
          onCloseWindow: () => windowClosed += 1,
        ),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.text('Active Modal'), findsNothing);
      expect(inspectorOpen, isTrue);
      expect(tabs.isOnSecondaryTab, isTrue);

      // 2. Next layered close dismisses active side inspector before tab.
      expect(
        dispatchLayeredDesktopClose(
          router: router,
          isMacOS: false,
          onCloseWindow: () => windowClosed += 1,
        ),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(inspectorOpen, isFalse);
      expect(tabs.isOnSecondaryTab, isTrue);

      // 3. Next Ctrl+W via KeyboardBack closes the active secondary tab.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(tabs.tabCount, 1);
      expect(tabs.activeIndex, 0);

      // macOS File menu switches back to "Close" on root tab.
      menus = buildDesktopPlatformMenus(
        l10n: l10n,
        router: router,
        isFullScreen: false,
        destinations: HomeDestination.values,
      );
      final fileMenusRoot = menus
          .whereType<PlatformMenu>()
          .elementAt(1)
          .menus
          .whereType<PlatformMenuItemGroup>()
          .expand((g) => g.members)
          .toList();
      expect(fileMenusRoot.any((m) => m.label == l10n.windowClose), isTrue);

      // 4. On root tab: Windows/Linux is a no-op; macOS invokes onCloseWindow.
      expect(
        dispatchLayeredDesktopClose(
          router: router,
          isMacOS: false,
          onCloseWindow: () => windowClosed += 1,
        ),
        isFalse,
      );
      expect(windowClosed, 0);

      expect(
        dispatchLayeredDesktopClose(
          router: router,
          isMacOS: true,
          onCloseWindow: () => windowClosed += 1,
        ),
        isTrue,
      );
      expect(windowClosed, 1);
    },
  );

  testWidgets(
    'Secondary tab switches unfocus root editor, isolate mouse back, skip hidden inspector, dedupe search filters, and focus root on GoRouter navigation',
    (tester) async {
      // P2-1: search tabs with different filters have distinct dedupe keys.
      const q1 = IllustSearchQuery(
        keyword: 'cat',
        filters: IllustSearchFilters(sort: SearchSort.dateDesc),
      );
      const q2 = IllustSearchQuery(
        keyword: 'cat',
        filters: IllustSearchFilters(sort: SearchSort.popularDesc),
      );
      expect(
        SearchTabTarget(q1).dedupeKey,
        isNot(SearchTabTarget(q2).dedupeKey),
      );

      final tabs = DesktopWorkspaceTabsController()..attachAsActive();
      addTearDown(() {
        tabs.detachIfActive();
        tabs.dispose();
      });

      final router = GoRouter(
        initialLocation: '/recommended',
        routes: [
          GoRoute(
            path: '/recommended',
            builder: (_, _) =>
                const Scaffold(body: TextField(key: Key('root-text-field'))),
          ),
          GoRoute(
            path: '/downloads',
            builder: (_, _) => const Scaffold(body: Text('Downloads')),
          ),
        ],
      );
      addTearDown(router.dispose);

      tabs.openBackgroundTab(
        title: 'Secondary',
        icon: UiIcons.chevronRight,
        builder: (_) => const Scaffold(body: Text('Secondary Root')),
      );

      await tester.pumpWidget(
        localizedRouterApp(
          router,
          locale: const Locale('en'),
          builder: (context, child) => DesktopWorkspaceTabsScope(
            controller: tabs,
            child: KeyboardBack(
              router: router,
              destinations: HomeDestination.values,
              child: DesktopWorkspaceTabHost(
                controller: tabs,
                rootChild: child!,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // P2-9: focusing root TextField then switching to secondary tab clears
      // focus so isTextEditingFocused() is false.
      await tester.tap(find.byKey(const Key('root-text-field')));
      await tester.pump();
      expect(isTextEditingFocused(), isTrue);

      tabs.selectTab(1);
      await tester.pumpAndSettle();
      expect(isTextEditingFocused(), isFalse);

      // P1-2: mouse back button pops a pushed route inside the active
      // secondary tab without touching the offstage root router.
      final secondaryNav = Navigator.of(tabs.activeSecondaryContext!);
      secondaryNav.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Secondary Pushed')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Secondary Pushed'), findsOneWidget);

      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      );
      await mouse.addPointer(location: const Offset(200, 200));
      await mouse.down(const Offset(200, 200));
      await tester.pump();
      await mouse.up();
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(find.text('Secondary Pushed'), findsNothing);
      expect(find.text('Secondary Root'), findsOneWidget);

      // P2-10: an offstage inspector (isActive: false) is ignored by layered
      // close so Ctrl+W closes the visible secondary tab instead.
      var offstageDismissed = false;
      bool dismissHidden() {
        offstageDismissed = true;
        return true;
      }

      DesktopInspectorDismissRegistry.register(
        dismissHidden,
        isActive: () => false,
      );
      addTearDown(
        () => DesktopInspectorDismissRegistry.unregister(dismissHidden),
      );
      expect(DesktopInspectorDismissRegistry.hasActive, isFalse);

      // P1-1: root-level navigation (e.g. tray openDownloadsFromRouter)
      // switches back to tab 0 so the target route is visible.
      openDownloadsFromRouter(router, rail: false);
      await tester.pumpAndSettle();
      expect(tabs.activeIndex, 0);
      expect(find.text('Downloads'), findsOneWidget);

      // Switching back to tab 1 and invoking layered close closes tab 1 while
      // leaving the hidden inspector untouched.
      tabs.selectTab(1);
      await tester.pumpAndSettle();
      expect(
        dispatchLayeredDesktopClose(router: router, isMacOS: false),
        isTrue,
      );
      expect(offstageDismissed, isFalse);
      expect(tabs.tabCount, 1);
      expect(tabs.activeIndex, 0);
    },
  );
}
