import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/network_restore_signal.dart';
import 'package:parfait/core/paging/paged_feed_controller.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

void main() {
  group('retry on network restore (HCI 9)', () {
    test('only the way back from no network counts as a restore', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
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
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: replicaTheme(Brightness.light),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: state),
          ),
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
      MaterialApp(
        theme: replicaTheme(Brightness.light),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: FeedTail(
            feed: const PagedFeedState(
              initialPhase: FeedPhase.idle,
              loadMorePaused: true,
            ),
            onRetry: () => continued++,
            retryLabel: 'Retry',
          ),
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
}
