import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/icons/ui_icons.dart';
import 'package:parfait/app/layout/card_columns.dart';
import 'package:parfait/app/layout/content_widths.dart';
import 'package:parfait/app/motion/removal.dart';
import 'package:parfait/app/pull_to_refresh.dart';
import 'package:parfait/app/scroll_behavior.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_progress_bar.dart';
import 'package:parfait/app/widgets/app_slider.dart';
import 'package:parfait/app/widgets/app_snack_bar.dart';
import 'package:parfait/app/widgets/app_spinner.dart';
import 'package:parfait/app/widgets/app_tab_bar.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'package:parfait/app/widgets/author_row.dart';
import 'package:parfait/app/widgets/entity_row.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/master_detail_workspace.dart';
import 'package:parfait/app/widgets/person_card.dart';
import 'package:parfait/app/widgets/scroll_edge_fade.dart';
import 'package:parfait/app/widgets/settings/settings_anchor.dart';
import 'package:parfait/app/widgets/settings/settings_group.dart';
import 'package:parfait/app/widgets/skeleton/func_skeleton.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/network_restore_signal.dart';
import 'package:parfait/core/paging/paged_feed_controller.dart';
import 'package:parfait/features/login/login_webview_error_card.dart';
import 'package:parfait/features/settings/settings_catalog.dart';
import 'helpers/fake_account.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';
import 'helpers/prompt_host.dart';
import 'helpers/view_size.dart';

Future<GoRouter> _pumpAuthorOnRouter(WidgetTester tester, Widget row) async {
  final router = pixivRouter('/recommended');
  await tester.pumpWidget(
    localizedRouterApp(
      router,
      overrides: await signedInAccountOverrides(
        const Account(id: '100', userId: 100, name: 't'),
      ),
    ),
  );
  await tester.pump();
  router.routerDelegate.navigatorKey.currentState!.push(
    PageRouteBuilder<void>(
      pageBuilder: (context, _, _) => Scaffold(
        body: Center(child: SizedBox(width: 300, child: row)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return router;
}

void main() {
  group('retry on network restore (HCI 9)', () {
    test('only the way back from no network counts as a restore', () {
      final container = ProviderContainer.test();
      final signal = container.read(networkRestoreSignalProvider.notifier);
      int restores() => container.read(networkRestoreSignalProvider);

      signal.observe('wifi');
      signal.observe('mobile');
      expect(restores(), 0, reason: 'switching live networks');
      signal.observe(offlineNetworkIdentity);
      signal.observe('vpn+wifi');
      expect(restores(), 1);
      signal.observe('wifi');
      expect(restores(), 1);
    });

    Future<ProviderContainer> pumpError(
      WidgetTester tester,
      Widget state,
    ) async {
      final container = ProviderContainer.test();
      await tester.pumpWidget(
        localizedApp(
          container: container,
          locale: null,
          theme: replicaTheme(Brightness.light),
          body: state,
        ),
      );
      return container;
    }

    void restore(ProviderContainer container) {
      container.read(networkRestoreSignalProvider.notifier)
        ..observe(offlineNetworkIdentity)
        ..observe('wifi');
    }

    testWidgets('a connection failure retries once per restore', (
      tester,
    ) async {
      var retries = 0;
      final container = await pumpError(
        tester,
        FeedError(
          title: 'Failed',
          error: const ApiNetworkError('socket closed'),
          onRetry: () => retries++,
          retryLabel: 'Retry',
        ),
      );
      restore(container);
      await tester.pump();
      expect(retries, 1);
      container.read(networkRestoreSignalProvider.notifier).observe('mobile');
      await tester.pump();
      expect(retries, 1, reason: 'a network switch is not a restore');
      restore(container);
      await tester.pump();
      expect(retries, 2);
    });

    testWidgets('a failed page further down retries too', (tester) async {
      var retries = 0;
      final container = await pumpError(
        tester,
        FeedTail(
          feed: const PagedFeedState(
            initialPhase: FeedPhase.idle,
            loadMorePhase: FeedPhase.error,
            loadMoreError: ApiTimeout(),
          ),
          onRetry: () => retries++,
          retryLabel: 'Retry',
        ),
      );
      restore(container);
      await tester.pump();
      expect(retries, 1);
    });

    testWidgets('a failure the network does not explain stays put', (
      tester,
    ) async {
      var retries = 0;
      final container = await pumpError(
        tester,
        FeedError(
          title: 'Failed',
          error: const ApiHttpError(404),
          onRetry: () => retries++,
          retryLabel: 'Retry',
        ),
      );
      restore(container);
      await tester.pump();
      expect(retries, 0);
    });

    testWidgets(
      'FeedError exposes category-scoped settings action with GoRouter and LoginWebViewErrorCard offers browser fallback',
      (tester) async {
        // Without GoRouter, network errors omit secondary action safely.
        await pumpError(
          tester,
          FeedError(
            title: 'Failed',
            error: const ApiNetworkError('socket closed'),
            onRetry: () {},
            retryLabel: 'Retry',
          ),
        );
        expect(find.text('网络'), findsNothing);

        final visited = <String>[];
        GoRouter buildRouter(Object error) => GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => Scaffold(
                body: FeedError(
                  title: 'Failed',
                  error: error,
                  onRetry: () {},
                  retryLabel: 'Retry',
                ),
              ),
            ),
            GoRoute(
              path: '/settings/network',
              builder: (_, _) {
                visited.add('/settings/network');
                return const Scaffold(body: Text('net-settings'));
              },
            ),
            GoRoute(
              path: '/settings/account',
              builder: (_, _) {
                visited.add('/settings/account');
                return const Scaffold(body: Text('acct-settings'));
              },
            ),
          ],
        );

        final container = ProviderContainer.test();
        final netRouter = buildRouter(const ApiTimeout());
        addTearDown(netRouter.dispose);
        await tester.pumpWidget(
          localizedRouterApp(netRouter, container: container),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('网络'));
        await tester.pumpAndSettle();
        expect(visited, ['/settings/network']);

        await tester.pumpWidget(const SizedBox.shrink());
        final authRouter = buildRouter(const ApiUnauthorized());
        addTearDown(authRouter.dispose);
        await tester.pumpWidget(
          localizedRouterApp(authRouter, container: container),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('账号'));
        await tester.pumpAndSettle();
        expect(visited, ['/settings/network', '/settings/account']);

        await tester.pumpWidget(const SizedBox.shrink());
        final permRouter = buildRouter(const ApiHttpError(404));
        addTearDown(permRouter.dispose);
        await tester.pumpWidget(
          localizedRouterApp(permRouter, container: container),
        );
        await tester.pumpAndSettle();
        expect(find.text('网络'), findsNothing);
        expect(find.text('账号'), findsNothing);

        // LoginWebViewErrorCard shows external browser fallback on recoverable errors.
        var openedBrowser = false;
        await tester.pumpWidget(
          localizedApp(
            body: LoginWebViewErrorCard(
              message: 'Load failed',
              fatal: false,
              signup: false,
              onReload: () {},
              onRestart: () {},
              onDismiss: () {},
              onOpenInBrowser: () => openedBrowser = true,
            ),
          ),
        );
        await tester.tap(find.text('在浏览器打开'));
        expect(openedBrowser, isTrue);
      },
    );
  });

  testWidgets('a section retries twice on its own, then waits for the user', (
    tester,
  ) async {
    var retries = 0;
    Future<void> show({required bool failed, Object? error}) =>
        tester.pumpWidget(
          AutoRetry(
            failed: failed,
            error: error,
            onRetry: () => retries++,
            child: const SizedBox(),
          ),
        );
    const rateLimited = ApiRateLimited(Duration(seconds: 5));
    final [first, second] = AutoRetry.delays;

    await show(failed: true, error: const ApiTimeout());
    await tester.pump(first);
    expect(retries, 1);
    await show(failed: false);
    // A rate limit waits at least as long as the server asked.
    await show(failed: true, error: rateLimited);
    await tester.pump(second);
    expect(retries, 1);
    await tester.pump(rateLimited.retryAfter! - second);
    expect(retries, 2);
    await show(failed: false);
    await show(failed: true, error: const ApiTimeout());
    await tester.pump(const Duration(minutes: 1));
    expect(retries, 2);
  });

  testWidgets('a paused feed tail offers continue, which pages on', (
    tester,
  ) async {
    var continued = 0;
    await tester.pumpWidget(
      localizedApp(
        locale: const Locale('en'),
        theme: replicaTheme(Brightness.light),
        body: FeedTail(
          feed: const PagedFeedState(
            initialPhase: FeedPhase.idle,
            loadMorePaused: true,
          ),
          onRetry: () => continued++,
          retryLabel: 'Retry',
        ),
      ),
    );
    final button = find.byKey(const Key('feed-continue-loading'));
    expect(button, findsOneWidget);
    expect(find.text('Continue loading'), findsOneWidget);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    await tester.tap(button);
    expect(continued, 1);
  });

  testWidgets('a text bone is as tall as a line of its style at every '
      'text scale', (tester) async {
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    const style = TextStyle(fontSize: 14, height: 1.4);
    for (final scale in [1.0, 2.0, 1.0]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              SkeletonBone.text(width: 80, style: style),
              Text('x', style: style),
            ],
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(SkeletonBone)).height,
        tester.getSize(find.text('x')).height,
      );
    }
  });

  testWidgets(
    'an empty state stands as high under a bar with tabs as without',
    (tester) async {
      Future<double> centerUnder(PreferredSizeWidget? tabs) async {
        await tester.pumpWidget(
          localizedApp(
            theme: replicaTheme(Brightness.light),
            home: DefaultTabController(
              length: 2,
              child: Scaffold(
                appBar: AppTopBar(title: const Text('page'), bottom: tabs),
                body: const FeedEmpty(title: 'nothing here'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return tester.getCenter(find.text('nothing here')).dy;
      }

      final plain = await centerUnder(null);
      final tabbed = await centerUnder(const AppTabBar(labels: ['a', 'b']));
      expect(tabbed, moreOrLessEquals(plain));
    },
  );

  testWidgets('a capped top bar follows the content column', (tester) async {
    setViewSize(tester, const Size(1400, 800));
    await tester.pumpWidget(
      localizedApp(
        theme: replicaTheme(Brightness.light),
        home: Scaffold(
          appBar: AppTopBar(
            contentWidth: ContentWidths.settings,
            leading: IconButton(
              onPressed: () {},
              icon: const Icon(Icons.arrow_back),
            ),
            title: const Text('设置'),
            actions: [
              IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
            ],
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 600-wide column in a 1400 window: 400 free on each side.
    const inset = 400.0;
    final back = tester.getRect(find.byIcon(Icons.arrow_back));
    final action = tester.getRect(find.byIcon(Icons.more_vert));
    final title = tester.getRect(find.text('设置'));
    expect(back.left, greaterThanOrEqualTo(inset));
    expect(back.center.dx, lessThan(inset + kToolbarHeight));
    expect(action.right, lessThanOrEqualTo(1400 - inset));
    expect(action.right, greaterThan(1400 - inset - kToolbarHeight));
    // The title starts just past the back control, inside the column.
    expect(
      title.left,
      closeTo(inset + kToolbarHeight + NavigationToolbar.kMiddleSpacing, .5),
    );
    // Only the controls move in: the bar's surface still spans the page.
    expect(tester.getRect(find.byType(AppBar)).width, 1400);
  });

  testWidgets('an empty state scrolls only when the window cannot hold it', (
    tester,
  ) async {
    Widget empty() => FeedEmpty(
      icon: Icons.search,
      title: 'nothing here',
      detail: 'try another search',
      retryLabel: 'refresh',
      onRefresh: () async {},
      actionLabel: 'edit',
      onAction: () {},
    );

    // A turned phone's short window under a bar with a search row and a
    // filter row: the buttons are reached by scrolling, nothing overflows.
    setViewSize(tester, const Size(568, 320));
    await tester.pumpWidget(
      localizedApp(
        theme: replicaTheme(Brightness.light),
        home: Scaffold(
          appBar: AppTopBar(
            title: const Text('page'),
            bottom: const PreferredSize(
              preferredSize: Size.fromHeight(96),
              child: SizedBox.shrink(),
            ),
          ),
          body: empty(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('edit'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('edit')).bottom, lessThanOrEqualTo(320));

    // Laid out at its own height in a page's scroll, it leaves the drag to
    // that scroll, which pulls down to refresh.
    final page = ScrollController();
    addTearDown(page.dispose);
    setViewSize(tester, const Size(400, 800));
    await tester.pumpWidget(
      localizedApp(
        theme: replicaTheme(Brightness.light),
        // The app's: a page's scroll and a status view's take any drag.
        scrollBehavior: const FuncScrollBehavior(),
        home: Scaffold(
          body: CustomScrollView(
            controller: page,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverFillRemaining(hasScrollBody: false, child: empty()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final drag = await tester.startGesture(
      tester.getCenter(find.text('nothing here')),
    );
    await drag.moveBy(const Offset(0, 40));
    await drag.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(page.offset, lessThan(0));
    final inner = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(FeedEmpty),
        matching: find.byType(Scrollable),
      ),
    );
    expect(inner.position.pixels, 0);
    await drag.up();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'AppTopBar keeps disabled IconButton and TextButton foreground alpha >= 0.45',
    (tester) async {
      setViewSize(tester, const Size(390, 800));
      for (final brightness in Brightness.values) {
        final theme = replicaTheme(brightness);
        final tokens = theme.extension<FuncSemanticTokens>()!;
        await tester.pumpWidget(
          localizedApp(
            theme: theme,
            home: Scaffold(
              appBar: AppTopBar(
                title: const Text('History'),
                actions: [
                  TextButton(onPressed: null, child: const Text('Manage')),
                  IconButton(
                    tooltip: 'Clear',
                    onPressed: null,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              body: const SizedBox.shrink(),
            ),
          ),
        );
        await tester.pump();

        final bar = tester.widget<AppBar>(find.byType(AppBar));
        expect(bar.backgroundColor, isNull);
        expect(theme.appBarTheme.backgroundColor, tokens.canvas);
        final textColor = DefaultTextStyle.of(
          tester.element(find.text('Manage')),
        ).style.color!;
        final iconColor = IconTheme.of(
          tester.element(find.byIcon(Icons.delete_outline)),
        ).color!;
        expect(textColor.a, greaterThanOrEqualTo(0.45), reason: '$brightness');
        expect(iconColor.a, greaterThanOrEqualTo(0.45), reason: '$brightness');
      }
    },
  );

  testWidgets(
    'MasterDetailWorkspace wraps scrollable masterBody in vertical ScrollEdgeFade',
    (tester) async {
      setViewSize(tester, const Size(1280, 800));
      await tester.pumpWidget(
        localizedApp(
          theme: replicaTheme(Brightness.light),
          home: MasterDetailWorkspace(
            title: const Text('Settings'),
            masterBody: ListView.builder(
              itemCount: 30,
              itemBuilder: (_, index) =>
                  SizedBox(height: 56, child: Text('Section $index')),
            ),
            detail: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final fadeFinder = find.descendant(
        of: find.byType(MasterDetailWorkspace),
        matching: find.byType(ScrollEdgeFade),
      );
      expect(fadeFinder, findsOneWidget);
      expect(tester.widget<ScrollEdgeFade>(fadeFinder).axis, Axis.vertical);
      expect(tester.state<ScrollEdgeFadeState>(fadeFinder).fades, (
        false,
        true,
      ));
    },
  );

  testWidgets(
    'unified SettingsGroup card, FuncBottomNav hairline, SakuraRefreshIndicator, and AppSpinner',
    (tester) async {
      setViewSize(tester, const Size(390, 800));
      final theme = replicaTheme(Brightness.light);
      final tokens = theme.extension<FuncSemanticTokens>()!;
      final removals = RemovalController();
      addTearDown(removals.dispose);
      bool isHairline(Widget w) =>
          w is ColoredBox && w.color == tokens.brandHairline;

      await tester.pumpWidget(
        localizedApp(
          theme: theme,
          home: Scaffold(
            body: SettingsFocusScope(
              target: SettingsPageRef.theme.id,
              child: RemovalScope(
                controller: removals,
                child: ListView(
                  children: [
                    SettingsGroup(
                      setting: SettingsPageRef.theme,
                      children: const [
                        Removable(
                          id: 'a',
                          child: ListTile(title: Text('A')),
                        ),
                        Removable(
                          id: 'b',
                          child: ListTile(title: Text('B')),
                        ),
                      ],
                    ),
                    MediaQuery(
                      data: const MediaQueryData(disableAnimations: true),
                      child: SakuraRefreshIndicator(
                        progress: 0.6,
                        spinning: true,
                        color: theme.colorScheme.primary,
                        trackColor: tokens.brandHairline,
                      ),
                    ),
                    const AppSpinner(value: 0.5),
                  ],
                ),
              ),
            ),
            bottomNavigationBar: FuncBottomNav(
              destinations: const [
                FuncBottomNavDestination(icon: Icons.home, label: 'Home'),
                FuncBottomNavDestination(icon: Icons.person, label: 'Me'),
              ],
              selectedIndex: 0,
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(SettingsCard), findsOneWidget);
      Finder in_(Type p, Finder m) =>
          find.descendant(of: find.byType(p), matching: m);
      final card = tester.widget<Material>(
        in_(SettingsCard, find.byType(Material)).first,
      );
      expect(
        (card.shape! as RoundedRectangleBorder).side.color,
        tokens.brandHairline,
      );
      expect(in_(SettingsGroup, find.byType(SettingMarkOverlay)), findsOne);
      final divider = in_(SettingsGroup, find.byWidgetPredicate(isHairline));
      expect(divider, findsOneWidget);

      final exitFuture = removals.playExit(const ['b']);
      await tester.pumpAndSettle();
      await exitFuture;
      expect(divider, findsNothing);

      expect(find.byType(SakuraRefreshIndicator), findsOneWidget);
      final spinner = tester.widget<CircularProgressIndicator>(
        in_(AppSpinner, find.byType(CircularProgressIndicator)),
      );
      expect(spinner.backgroundColor, tokens.brandHairline);
      expect(spinner.strokeCap, StrokeCap.round);
      final navBox = tester.widget<DecoratedBox>(
        in_(FuncBottomNav, find.byType(DecoratedBox)).first,
      );
      expect(
        (navBox.decoration as BoxDecoration).border,
        Border(top: BorderSide(color: tokens.brandHairline)),
      );
    },
  );

  testWidgets(
    'AppSlider bridges FSlider with ExcludeFocus and preserves scrubber Slider',
    (tester) async {
      await tester.pumpWidget(
        localizedApp(
          body: Column(
            children: [
              AppSlider(
                value: 2,
                min: 1,
                max: 5,
                divisions: 4,
                onChanged: (_) {},
              ),
              AppSlider(value: 0.5, onChanged: (_) {}),
              AppSlider.scrubber(value: 0.5, onChanged: (_) {}),
            ],
          ),
        ),
      );

      expect(find.byType(FSlider), findsNWidgets(2));
      expect(
        find.ancestor(
          of: find.byType(FSlider),
          matching: find.byWidgetPredicate(
            (w) => w is ExcludeFocus && w.excluding,
          ),
        ),
        findsNWidgets(2),
      );
      expect(find.byType(Slider), findsOneWidget);
    },
  );

  testWidgets(
    'AppProgressBar renders FDeterminateProgress when bounded and FProgress when null',
    (tester) async {
      await tester.pumpWidget(
        localizedApp(
          body: const Column(
            children: [AppProgressBar(value: 1.5), AppProgressBar()],
          ),
        ),
      );

      final determinate = tester.widget<FDeterminateProgress>(
        find.byType(FDeterminateProgress),
      );
      expect(determinate.value, 1.0);
      expect(find.byType(FProgress), findsOneWidget);
    },
  );

  testWidgets('app snackbars are exposed as live regions', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: localizedApp(
          locale: null,
          builder: promptHostBuilder,
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppSnackBar(context, 'Saved'),
              child: const Text('Show'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.bySemanticsLabel('Saved'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Saved')),
      isSemantics(label: 'Saved', isLiveRegion: true),
    );
  });

  group('EntityRow', () {
    Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('tap and long-press reach the row', (tester) async {
      var taps = 0;
      var longPresses = 0;
      await tester.pumpWidget(
        host(
          EntityRow(
            leading: const SizedBox(width: 48),
            title: 'Pressable',
            onTap: () => taps++,
            onLongPress: () => longPresses++,
          ),
        ),
      );
      await tester.tap(find.text('Pressable'));
      await tester.longPress(find.text('Pressable'));
      expect(taps, 1);
      expect(longPresses, 1);
    });

    testWidgets('progress slot honors the null vs zero boundary', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const EntityRow(leading: SizedBox(width: 48), title: 'No progress'),
        ),
      );
      expect(find.byType(AppProgressBar), findsNothing);

      await tester.pumpWidget(
        host(
          const EntityRow(
            leading: SizedBox(width: 48),
            title: 'At the start',
            progress: 0,
          ),
        ),
      );
      final indicator = tester.widget<AppProgressBar>(
        find.byType(AppProgressBar),
      );
      expect(indicator.value, 0);
    });
  });

  group('sliver cache ramp', () {
    for (final grid in [false, true]) {
      testWidgets(
        'a ${grid ? 'grid' : 'card list'} that jumps far fills the screen in its first frame',
        (tester) async {
          setViewSize(tester, const Size(400, 800));
          final controller = ScrollController();
          addTearDown(controller.dispose);
          Widget card(BuildContext context, int index) => _RampCard(index);
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                home: CustomScrollView(
                  controller: controller,
                  scrollCacheExtent: kFeedCacheExtent,
                  slivers: [
                    if (grid)
                      IllustFeedGrid(itemCount: 200, itemBuilder: card)
                    else
                      SliverCardList(itemCount: 200, itemBuilder: card),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          Iterable<(int, Rect)> shown() =>
              [
                for (final card in tester.widgetList<_RampCard>(
                  find.byType(_RampCard),
                ))
                  (card.index, tester.getRect(find.byWidget(card))),
              ].where(
                (card) => card.$2.overlaps(Offset.zero & const Size(400, 800)),
              );
          final before = shown().map((card) => card.$1).reduce(math.max);

          controller.jumpTo(3000);
          await tester.pump();
          expect(
            shown().map((card) => card.$1),
            everyElement(greaterThan(before)),
          );
          expect(
            shown().map((card) => card.$2.bottom),
            contains(greaterThanOrEqualTo(800 - FuncSpacing.md)),
          );
          await tester.pumpAndSettle();
        },
      );
    }
  });

  group('AuthorRow and PersonCard', () {
    testWidgets('the whole row is one 48dp target that opens the profile', (
      tester,
    ) async {
      final router = await _pumpAuthorOnRouter(
        tester,
        const AuthorRow(userId: 42, name: 'author'),
      );

      final target = find.byType(InkWell);
      expect(target, findsOneWidget);
      expect(
        tester.getSize(target).height,
        greaterThanOrEqualTo(AuthorRow.minHeight),
      );
      expect(tester.getSize(target).width, 300);
      final chevron = find.descendant(
        of: target,
        matching: find.byIcon(UiIcons.chevronRight),
      );
      expect(
        tester.getTopLeft(chevron).dx,
        moreOrLessEquals(tester.getTopRight(find.text('author')).dx),
      );

      await tester.tapAt(
        tester.getRect(target).centerRight - const Offset(8, 0),
      );
      await tester.pump();
      expect(router.state.uri.path, '/recommended/user/42');
    });

    testWidgets('a person card is one target; its trailing button is its own', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      var opened = 0;
      var followed = 0;
      await tester.pumpWidget(
        localizedApp(
          body: Center(
            child: SizedBox(
              width: 300,
              child: PersonCard(
                onTap: () => opened++,
                tapHint: 'open',
                trailing: TextButton(
                  onPressed: () => followed++,
                  child: const Text('follow'),
                ),
                child: const Text('name'),
              ),
            ),
          ),
        ),
      );

      final card = find.byType(PersonCard);
      expect(
        tester.getSize(card).height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );
      expect(
        tester.getSemantics(
          find.descendant(of: card, matching: find.byType(InkWell)).first,
        ),
        isSemantics(
          label: 'name',
          isButton: true,
          hasTapAction: true,
          onTapHint: 'open',
        ),
      );

      await tester.tapAt(tester.getRect(card).centerLeft + const Offset(8, 0));
      await tester.tap(find.text('follow'));
      expect((opened, followed), (1, 1));
      semantics.dispose();
    });
  });
}

class _RampCard extends StatelessWidget {
  const _RampCard(this.index);

  final int index;

  @override
  Widget build(BuildContext context) => const SizedBox(height: 100);
}
