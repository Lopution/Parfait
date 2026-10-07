import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/motion/state_fade.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/author_summary.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/app/widgets/replica_button.dart';
import 'package:parfait/app/widgets/replica_scaffold.dart';
import 'package:parfait/app/widgets/tag_chips.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/network_restore_signal.dart';
import 'package:parfait/core/paging/paged_feed_controller.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

Widget _wrap(Widget child) {
  return MaterialApp(theme: replicaTheme(Brightness.light), home: child);
}

void main() {
  testWidgets('FeedLoading renders the indicator and optional caption', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const Scaffold(body: FeedLoading())));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Text), findsNothing);

    await tester.pumpWidget(
      _wrap(const Scaffold(body: FeedLoading(label: 'Loading feed'))),
    );
    expect(find.text('Loading feed'), findsOneWidget);
    final indicator = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(indicator.semanticsLabel, 'Loading feed');
  });

  testWidgets('ReplicaScaffold passes actions and FAB through', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ReplicaScaffold(
          title: const Text('Page'),
          actions: const [Icon(Icons.settings)],
          floatingActionButton: const FloatingActionButton(
            onPressed: null,
            child: Icon(Icons.add),
          ),
          child: const SizedBox.shrink(),
        ),
      ),
    );

    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    // A root-level scaffold has no implicit back button.
    expect(find.byType(BackButtonIcon), findsNothing);
  });

  testWidgets('the outlined ReplicaButton keeps the page colour in dark mode', (
    tester,
  ) async {
    final theme = replicaTheme(Brightness.dark);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Column(
            children: [
              ReplicaButton(
                label: 'Register',
                outlined: true,
                onPressed: () {},
              ),
              ReplicaButton(label: 'Log in', onPressed: () {}),
            ],
          ),
        ),
      ),
    );
    Material surface(String label) => tester.widget<Material>(
      find
          .ancestor(of: find.text(label), matching: find.byType(Material))
          .first,
    );
    Color? ink(String label) =>
        tester.widget<Text>(find.text(label)).style?.color;

    expect(surface('Register').color, Colors.transparent);
    expect(ink('Register'), theme.colorScheme.primary);
    expect(surface('Log in').color, theme.colorScheme.primary);
    expect(ink('Log in'), theme.colorScheme.onPrimary);
  });

  testWidgets('TagChip exposes tap and block-mode selected semantics', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      _wrap(
        Scaffold(
          body: TagChip(
            label: 'cat',
            blockMode: true,
            blocked: true,
            onTap: () => tapped++,
          ),
        ),
      ),
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.selected == true,
      ),
      findsOneWidget,
    );
    await tester.tap(find.byType(TagChip));
    expect(tapped, 1);
  });

  testWidgets('tag chips keep a 48dp target with no dead zone between them', (
    tester,
  ) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      _wrap(
        Scaffold(
          body: Center(
            child: TagChips(
              children: [
                TagChip(label: 'cat', onTap: () => tapped.add('cat')),
                TagChip(
                  label: 'girl',
                  translated: '女の子',
                  onTap: () => tapped.add('girl'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final cat = tester.getRect(find.byType(TagChip).first);
    final girl = tester.getRect(find.byType(TagChip).last);
    final pill = find.descendant(
      of: find.byType(TagChip).first,
      matching: find.byWidgetPredicate(
        (w) => w is DecoratedBox && w.decoration is ShapeDecoration,
      ),
    );

    expect(tester.getSize(pill).height, 32);
    expect(cat.height, greaterThanOrEqualTo(kMinInteractiveDimension));
    expect(girl.left, cat.right, reason: 'neighbouring targets touch');

    // Above the pill, and on either side of the gap between two pills.
    await tester.tapAt(Offset(cat.center.dx, cat.top + 2));
    await tester.tapAt(Offset(cat.right - 1, cat.center.dy));
    await tester.tapAt(Offset(girl.left + 1, girl.center.dy));
    expect(tapped, ['cat', 'cat', 'girl']);
  });

  testWidgets('AuthorSummary reports taps and ellipsizes long names', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      _wrap(
        Scaffold(
          body: SizedBox(
            width: 240,
            child: AuthorSummary(
              name: 'An Extremely Long Author Name That Must Ellipsize',
              account: 'long_author_account',
              imageUrl: null,
              onTap: () => tapped++,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(AuthorSummary));
    expect(tapped, 1);
  });

  testWidgets('FeedEmpty still fits under a 2x text scale', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: MaterialApp(
          theme: replicaTheme(Brightness.light),
          home: Scaffold(
            body: FeedEmpty(
              title: 'Nothing here',
              detail: 'Long detail text wraps instead of overflowing.',
              onRefresh: () async {},
              retryLabel: 'Retry',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('empty and error states fade in when they appear', (
    tester,
  ) async {
    double opacityOver(String text) => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.text(text),
                matching: find.descendant(
                  of: find.byType(StateFade),
                  matching: find.byType(FadeTransition),
                ),
              )
              .first,
        )
        .opacity
        .value;

    for (final state in [
      const FeedEmpty(title: 'Nothing here'),
      FeedError(title: 'Failed', onRetry: () {}, retryLabel: 'Retry'),
    ]) {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: replicaTheme(Brightness.light),
            home: Scaffold(body: state),
          ),
        ),
      );
      final title = state is FeedEmpty ? 'Nothing here' : 'Failed';
      expect(opacityOver(title), 0);
      await tester.pumpAndSettle();
      expect(opacityOver(title), 1);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('MotionTokens.resolve collapses under disabled animations', (
    tester,
  ) async {
    Duration? resolved;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: replicaTheme(Brightness.light),
          home: Builder(
            builder: (context) {
              resolved = MotionTokens.resolve(context, MotionTokens.medium);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(resolved, Duration.zero);
  });
}
