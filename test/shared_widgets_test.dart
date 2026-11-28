import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/icons/ui_icons.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_snack_bar.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'package:parfait/app/widgets/author_row.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/app/widgets/person_card.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/network_restore_signal.dart';
import 'package:parfait/core/paging/paged_feed_controller.dart';
import 'package:parfait/features/login/login_webview_error_card.dart';
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
