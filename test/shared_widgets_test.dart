import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_tab_bar.dart';
import 'package:parfait/app/widgets/app_top_bar.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/app/widgets/skeleton/func_skeleton.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/network_restore_signal.dart';
import 'package:parfait/core/paging/paged_feed_controller.dart';
import 'helpers/localized_app.dart';

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
}
