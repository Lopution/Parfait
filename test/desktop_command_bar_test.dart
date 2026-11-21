import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/app.dart' show AppChrome;
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/layout/form_factor.dart';
import 'package:parfait/app/layout/window_layout_spec.dart'
    show WindowEnvironmentOverride;
import 'package:parfait/app/navigation/forward_history.dart';
import 'package:parfait/app/navigation/keyboard_back.dart';
import 'package:parfait/app/navigation/route_extras.dart' show IllustRouteExtra;
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/page_header.dart';
import 'package:parfait/app/widgets/search_field_button.dart';
import 'package:parfait/app/widgets/shell_rail.dart';
import 'package:parfait/app/window/desktop_command_bar.dart';
import 'package:parfait/app/window/desktop_menu_bar.dart';
import 'package:parfait/app/window/desktop_title_bar.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/navigation/home_destination.dart';
import 'package:parfait/core/platform/desktop_window_channel.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/features/home/home_page.dart';
import 'package:parfait/features/illust/detail/widgets/page_image.dart'
    show DetailPageImage;
import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'helpers/connectivity_channels.dart';
import 'helpers/detail_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/fake_settings.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';
import 'helpers/view_size.dart';

void _collectMenuItems(
  List<PlatformMenuItem> items,
  List<PlatformMenuItem> out,
) {
  for (final item in items) {
    out.add(item);
    switch (item) {
      case PlatformMenu(:final menus):
        _collectMenuItems(menus, out);
      case PlatformMenuItemGroup(:final members):
        _collectMenuItems(members, out);
      case _:
        break;
    }
  }
}

Future<Object?> _invokeNavCommand(String method) async {
  const codec = StandardMethodCodec();
  final completer = Completer<ByteData?>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'parfait/navigation_commands',
        codec.encodeMethodCall(MethodCall(method)),
        completer.complete,
      );
  final reply = await completer.future;
  return reply == null ? null : codec.decodeEnvelope(reply);
}

void main() {
  testWidgets(
    'DesktopCommandBar chrome, drag regions, header deduplication, and popovers',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        setViewSize(tester, const Size(1280, 800));
        await seedSettings(AppSettings.defaults());
        const altAccount = Account(id: '200', userId: 200, name: 'alt');
        await seedAccounts([
          testerAccount,
          altAccount,
        ], currentId: testerAccount.id);
        final credStore = FakeCredentialStore()
          ..seed(
            testerAccount.id,
            const Credential(accessToken: 'a1', refreshToken: 'r1'),
          )
          ..seed(
            altAccount.id,
            const Credential(accessToken: 'a2', refreshToken: 'r2'),
          );
        final router = GoRouter(
          initialLocation: '/recommended',
          routes: [
            GoRoute(
              path: '/recommended',
              builder: (context, _) => BranchRootScope(
                branchIndex: 0,
                child: Row(
                  children: [
                    SizedBox(
                      width: ShellRail.width,
                      child: ShellRail(
                        destinations: const [
                          FuncBottomNavDestination(
                            icon: Icons.home_outlined,
                            label: 'Home',
                          ),
                        ],
                        selectedIndex: 0,
                        onSelected: (_) {},
                        form: FormFactor.touch,
                        expanded: false,
                        onToggle: () {},
                        onBookmarks: () {},
                        onDownloads: () {},
                      ),
                    ),
                    const Expanded(
                      child: Row(
                        children: [
                          HeaderSearch(type: SearchResultType.illust),
                          HeaderRefresh(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);

        List<DesktopTitleBarRegion> lastRegions = const [];
        double? lastHeight;
        final commandScope = ValueNotifier<bool>(true);
        addTearDown(commandScope.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: accountProviderOverrides(credentialStore: credStore),
            child: ValueListenableBuilder<bool>(
              valueListenable: commandScope,
              builder: (context, active, _) => localizedRouterApp(
                router,
                builder: (ctx, child) => promptHostBuilder(
                  ctx,
                  DesktopChromeMetrics(
                    titleBarHeight: kDesktopCommandBarHeight,
                    usesSystemTitleBar: false,
                    showCustomButtons: true,
                    hostMetrics: const DesktopWindowPlatformMetrics(),
                    actions: DesktopWindowActions(
                      onMinimize: () {},
                      onToggleMaximize: () {},
                      onClose: () {},
                      onToggleFullScreen: () {},
                      onStartDragging: () {},
                      onTitleBarDoubleClick: () {},
                      onRegionsChanged: (r) => lastRegions = r,
                      onRegionsWithHeightChanged: (r, h) {
                        lastRegions = r;
                        lastHeight = h;
                      },
                    ),
                    child: DesktopCommandBarScope(
                      active: active,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (active)
                            DesktopCommandBar(
                              settings: AppSettings.defaults(),
                              router: router,
                            ),
                          Expanded(child: child!),
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

        final bar = find.byKey(const Key('desktop-command-bar'));
        expect(tester.getSize(bar).height, kDesktopCommandBarHeight);
        expect(lastHeight, kDesktopCommandBarHeight);
        expect(lastRegions.where((r) => r.kind == 'caption'), hasLength(2));
        expect(lastRegions.where((r) => r.kind == 'maximize'), hasLength(1));

        // Header deduplication: ShellRail header + HeaderSearch + HeaderRefresh collapse.
        expect(
          find.descendant(
            of: find.byType(ShellRail),
            matching: find.byIcon(AppIcons.sidebarExpand),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(HeaderRefresh),
            matching: find.byType(IconButton),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(HeaderSearch),
            matching: find.byType(SearchFieldButton),
          ),
          findsNothing,
        );

        // Filter popover toggles R-18 and AI filters.
        await tester.tap(find.byKey(const Key('desktop-command-filter')));
        await tester.pumpAndSettle();
        final r18Switch = find.byKey(const Key('desktop-command-filter-r18'));
        expect(r18Switch, findsOneWidget);
        expect(
          find.byKey(const Key('desktop-command-filter-ai')),
          findsOneWidget,
        );
        await tester.tap(r18Switch);
        await tester.pumpAndSettle();
        expect((await storedSettings().load()).enableLocalBlockR18, isTrue);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        // Account popover lists accounts + settings entry.
        await tester.tap(find.byKey(const Key('desktop-command-account')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(Key('desktop-command-account-${testerAccount.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('desktop-command-account-${altAccount.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('desktop-command-account-settings')),
          findsOneWidget,
        );
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        // Turning off DesktopCommandBarScope restores inline header controls.
        commandScope.value = false;
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(ShellRail),
            matching: find.byIcon(AppIcons.sidebarExpand),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(HeaderRefresh),
            matching: find.byType(IconButton),
          ),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'DesktopCommandBar compacts to 40dp toolbar without duplicate branding when usesSystemTitleBar is true',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        setViewSize(tester, const Size(1280, 800));
        await seedSettings(AppSettings.defaults());
        final router = GoRouter(
          initialLocation: '/recommended',
          routes: [
            GoRoute(
              path: '/recommended',
              builder: (_, _) => const SizedBox.shrink(),
            ),
            GoRoute(
              path: '/welcome',
              builder: (_, _) => const SizedBox.shrink(),
            ),
          ],
        );
        addTearDown(router.dispose);
        List<DesktopTitleBarRegion> lastRegions = const [];
        double? lastHeight;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [...await signedInAccountOverrides()],
            child: localizedRouterApp(
              router,
              builder: (ctx, child) => DesktopChromeMetrics(
                usesSystemTitleBar: true,
                hostMetrics: const DesktopWindowPlatformMetrics(
                  isWayland: true,
                  usesSystemTitleBar: true,
                ),
                actions: DesktopWindowActions(
                  onMinimize: () {},
                  onToggleMaximize: () {},
                  onClose: () {},
                  onToggleFullScreen: () {},
                  onStartDragging: () {},
                  onTitleBarDoubleClick: () {},
                  onRegionsChanged: (r) => lastRegions = r,
                  onRegionsWithHeightChanged: (r, h) {
                    lastRegions = r;
                    lastHeight = h;
                  },
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DesktopCommandBar(
                      settings: AppSettings.defaults(),
                      router: router,
                    ),
                    Expanded(child: child!),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final bar = find.byKey(const Key('desktop-command-bar'));
        expect(tester.getSize(bar).height, kDesktopCompactCommandBarHeight);
        expect(lastHeight, 0.0);
        expect(lastRegions, isEmpty);
        expect(find.text('Parfait'), findsNothing);
        expect(
          find.byKey(const Key('desktop-command-search-pill')),
          findsOneWidget,
        );

        router.go('/welcome');
        await tester.pumpAndSettle();
        expect(bar, findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'AppChrome hides DesktopCommandBar for touch form, provides Tooltip Overlay, and ShellRail keeps shortcuts',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        setViewSize(tester, const Size(1280, 800));
        final accountOverrides = await signedInAccountOverrides();
        final router = GoRouter(
          initialLocation: '/recommended',
          routes: [
            GoRoute(
              path: '/recommended',
              builder: (_, _) => const Scaffold(body: Text('home')),
            ),
          ],
        );
        addTearDown(router.dispose);

        Future<void> pumpWithForm(InterfaceForm form) async {
          final settings = AppSettings.defaults().copyWith(interfaceForm: form);
          await seedSettings(settings);
          await tester.pumpWidget(
            localizedRouterApp(
              router,
              overrides: accountOverrides,
              builder: (_, child) => WindowEnvironmentOverride(
                displaySize: const Size(1280, 800),
                targetPlatform: TargetPlatform.windows,
                desktopActions: DesktopWindowActions.noop,
                child: AppChrome(
                  settings: settings,
                  router: router,
                  child: child!,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await pumpWithForm(InterfaceForm.touch);
        expect(find.byKey(const Key('desktop-command-bar')), findsNothing);

        await pumpWithForm(InterfaceForm.auto);
        expect(find.byKey(const Key('desktop-command-bar')), findsOneWidget);
        final refresh = find.byKey(const Key('desktop-command-refresh'));
        expect(
          find.ancestor(of: refresh, matching: find.byType(Overlay)),
          findsWidgets,
        );
        expect(tester.widget<IconButton>(refresh).tooltip, isNotEmpty);

        await tester.pumpWidget(
          localizedApp(
            body: DesktopCommandBarScope(
              active: true,
              child: ShellRail(
                destinations: const [
                  FuncBottomNavDestination(icon: AppIcons.home, label: '推荐'),
                ],
                selectedIndex: 0,
                form: FormFactor.pc,
                expanded: false,
                canToggle: true,
                onToggle: () {},
                onSelected: (_) {},
                onBookmarks: () {},
                onDownloads: () {},
              ),
            ),
          ),
        );
        for (final icon in const [AppIcons.heart, AppIcons.downloading]) {
          expect(find.byIcon(icon), findsOneWidget);
        }
        expect(find.byIcon(AppIcons.sidebarExpand), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'DesktopMenuBar restricts to macOS and wires View, Navigation, Bookmarks, Downloads, and Search',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/recommended',
        routes: [
          GoRoute(
            path: '/recommended',
            builder: (_, _) => const SizedBox.shrink(),
          ),
        ],
      );
      addTearDown(router.dispose);

      for (final entry in <(TargetPlatform, Matcher)>[
        (TargetPlatform.windows, findsNothing),
        (TargetPlatform.linux, findsNothing),
        (TargetPlatform.macOS, findsOneWidget),
      ]) {
        debugDefaultTargetPlatformOverride = entry.$1;
        try {
          await tester.pumpWidget(
            localizedRouterApp(
              router,
              overrides: [...await signedInAccountOverrides()],
              builder: (_, child) => DesktopMenuBar(
                settings: AppSettings.defaults(),
                router: router,
                child: child!,
              ),
            ),
          );
          await tester.pump();
          expect(
            find.byType(PlatformMenuBar),
            entry.$2,
            reason: 'PlatformMenuBar gating on ${entry.$1}',
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }

      final l10n = lookupAppLocalizations(zhCN);
      final menus = buildDesktopPlatformMenus(
        l10n: l10n,
        router: router,
        railExpanded: false,
        isFullScreen: false,
        onToggleRail: () {},
      );
      final topLabels = [for (final m in menus.cast<PlatformMenu>()) m.label];
      expect(topLabels, [
        'Parfait',
        l10n.menuFile,
        l10n.menuNavigate,
        l10n.menuView,
        l10n.menuWindow,
      ]);
      expect(topLabels, isNot(contains('Edit')));

      final all = <PlatformMenuItem>[];
      _collectMenuItems(menus, all);
      final labels = {for (final item in all) item.label};
      for (final expected in [
        l10n.menuPreferences,
        l10n.railExpand,
        l10n.menuEnterFullScreen,
        l10n.navBack,
        l10n.navForward,
        l10n.refresh,
        l10n.railBookmarks,
        l10n.railDownloads,
        l10n.searchTitle,
      ]) {
        expect(labels, contains(expected));
      }
      final searchItem = all.firstWhere((e) => e.label == l10n.searchTitle);
      expect(
        searchItem.shortcut,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true),
      );
      final prefsItem = all.firstWhere((e) => e.label == l10n.menuPreferences);
      expect(
        prefsItem.shortcut,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true),
      );
      expect(HomeDestination.values, hasLength(5));
    },
  );

  testWidgets(
    'ForwardHistoryStack replays per-branch forward entries and debounces mouse back/forward',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        late GoRouter router;
        router = GoRouter(
          initialLocation: '/recommended',
          routes: [
            GoRoute(path: '/recommended', builder: (_, _) => const Text('rec')),
            GoRoute(
              path: '/recommended/work-1',
              builder: (_, _) => const Text('rec-1'),
            ),
            GoRoute(
              path: '/recommended/work-2',
              builder: (_, _) => const Text('rec-2'),
            ),
            GoRoute(path: '/ranking', builder: (_, _) => const Text('rank')),
            GoRoute(
              path: '/ranking/work-9',
              builder: (_, _) => const Text('rank-9'),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          localizedRouterApp(
            router,
            builder: (_, child) => KeyboardBack(router: router, child: child!),
          ),
        );
        await tester.pumpAndSettle();

        final history = ForwardHistoryStack.ofRouter(router);
        unawaited(router.push('/recommended/work-1'));
        await tester.pumpAndSettle();
        expect(find.text('rec-1'), findsOneWidget);
        expect(history.stateListenable.value.canGoBack, isTrue);
        expect(history.stateListenable.value.canGoForward, isFalse);

        // Mouse back pops and records forward entry in recommended bucket.
        final pointer = TestPointer(7, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(const Offset(50, 50)));
        await tester.sendEventToBinding(
          pointer.down(const Offset(50, 50), buttons: kBackMouseButton),
        );
        await tester.sendEventToBinding(pointer.up());
        await tester.pumpAndSettle();
        expect(find.text('rec'), findsOneWidget);
        expect(history.stateListenable.value.canGoForward, isTrue);

        // Cross-source debounce within 120ms: hardware pointer nav immediately
        // followed by parfait/navigation_commands channel suppresses duplicate.
        unawaited(router.push('/recommended/work-1'));
        await tester.pumpAndSettle();
        unawaited(router.push('/recommended/work-2'));
        await tester.pumpAndSettle();
        expect(find.text('rec-2'), findsOneWidget);

        await tester.sendEventToBinding(
          pointer.down(const Offset(50, 50), buttons: kBackMouseButton),
        );
        await tester.sendEventToBinding(pointer.up());
        await _invokeNavCommand('back');
        await tester.pumpAndSettle();
        // Second cross-source back within 120ms at the same push generation was
        // suppressed: stays on rec-1 instead of popping all the way to rec.
        expect(find.text('rec-1'), findsOneWidget);

        await tester.sendEventToBinding(
          pointer.down(const Offset(50, 50), buttons: kForwardMouseButton),
        );
        await tester.sendEventToBinding(pointer.up());
        await _invokeNavCommand('forward');
        await tester.pumpAndSettle();
        expect(find.text('rec-2'), findsOneWidget);

        // Per-branch isolation: switching to /ranking keeps forward stack separated.
        await history.goBack();
        await tester.pumpAndSettle();
        expect(history.stateListenable.value.canGoForward, isTrue);

        router.go('/ranking');
        await tester.pumpAndSettle();
        expect(history.stateListenable.value.canGoForward, isFalse);

        unawaited(router.push('/ranking/work-9'));
        await tester.pumpAndSettle();
        await history.goBack();
        await tester.pumpAndSettle();
        expect(history.stateListenable.value.canGoForward, isTrue);
        expect(await history.goForward(), isTrue);
        await tester.pumpAndSettle();
        expect(find.text('rank-9'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'AppChrome isolates Router BlockSemantics so DesktopCommandBar remains reachable in semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await seedSettings(AppSettings.defaults());
        await seedAccounts([testerAccount], currentId: testerAccount.id);
        final credStore = FakeCredentialStore(
          values: {
            testerAccount.id: const Credential(
              accessToken: 't',
              refreshToken: 'r',
            ),
          },
        );
        final router = GoRouter(
          initialLocation: '/recommended',
          routes: [
            GoRoute(
              path: '/recommended',
              builder: (_, _) => const Scaffold(body: Text('home body')),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          localizedRouterApp(
            router,
            overrides: accountProviderOverrides(credentialStore: credStore),
            builder: (context, child) => AppChrome(
              settings: AppSettings.defaults(),
              router: router,
              child: child!,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final refresh = find.byKey(const Key('desktop-command-refresh'));
        expect(refresh, findsOneWidget);
        final node = tester.getSemantics(refresh);
        expect(node.flagsCollection.isButton, isTrue);
        final rootNode = tester
            .binding
            .renderViews
            .first
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!;
        var reachedButtonFromRoot = false;
        var foundRefreshTooltip = false;
        bool visit(SemanticsNode current) {
          if (current.id == node.id) {
            reachedButtonFromRoot = true;
          }
          if (current.tooltip.isNotEmpty) {
            foundRefreshTooltip = true;
          }
          current.visitChildren(visit);
          return true;
        }

        visit(rootNode);
        expect(reachedButtonFromRoot, isTrue);
        expect(foundRefreshTooltip, isTrue);
      } finally {
        semantics.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'wide AppChrome keeps HomePage element and state mounted across ImageViewerPage push and pop',
    (tester) async {
      answerConnectivityChannels();
      for (final platform in const [
        TargetPlatform.windows,
        TargetPlatform.macOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          setViewSize(tester, const Size(1280, 800));
          VisibilityDetectorController.instance.updateInterval = Duration.zero;
          await seedSettings(AppSettings.defaults());
          final (container, _, _) = await makeWorld();
          final entity = parseIllust(illustJson(42));
          container.read(illustStoreProvider).mergeAll([entity]);
          final router = pixivRouter('/recommended');
          final metrics = platform == TargetPlatform.macOS
              ? const DesktopWindowPlatformMetrics(
                  usesSystemTitleBar: false,
                  trafficLightWidth: 78,
                  trafficLightHeight: 16,
                )
              : const DesktopWindowPlatformMetrics(usesSystemTitleBar: false);

          await tester.pumpWidget(
            localizedRouterApp(
              router,
              container: container,
              builder: (context, child) => WindowEnvironmentOverride(
                displaySize: const Size(1280, 800),
                targetPlatform: platform,
                desktopMetrics: metrics,
                desktopActions: DesktopWindowActions.noop,
                showSimulatedTrafficLights: platform == TargetPlatform.macOS,
                child: AppChrome(
                  settings: AppSettings.defaults(),
                  router: router,
                  child: child!,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final homeElement = tester.element(find.byType(HomePage));
          final homeState = tester.state(find.byType(HomePage));
          expect(find.byKey(const Key('desktop-command-bar')), findsOneWidget);

          unawaited(
            router.push<void>(
              '/recommended/illust/42',
              extra: IllustRouteExtra(entity: entity, heroScope: 'feed'),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byType(DetailPageImage).first);
          await tester.pumpAndSettle();
          expect(find.byType(ImageViewerPage), findsOneWidget);
          expect(find.byKey(const Key('desktop-command-bar')), findsNothing);
          expect(
            tester.element(find.byType(HomePage, skipOffstage: false)),
            same(homeElement),
            reason: '$platform HomePage element identity while viewer open',
          );
          expect(
            tester.state(find.byType(HomePage, skipOffstage: false)),
            same(homeState),
            reason: '$platform HomePage state identity while viewer open',
          );

          await tester.tap(find.byType(BackButton).last);
          await tester.pumpAndSettle();
          expect(find.byType(ImageViewerPage), findsNothing);
          expect(find.byKey(const Key('desktop-command-bar')), findsOneWidget);
          expect(
            tester.element(find.byType(HomePage)),
            same(homeElement),
            reason: '$platform HomePage element identity after viewer close',
          );
          expect(
            tester.state(find.byType(HomePage)),
            same(homeState),
            reason: '$platform HomePage state identity after viewer close',
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    },
  );
}
