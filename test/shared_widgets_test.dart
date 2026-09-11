import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pixiv_func/app/motion/motion_tokens.dart';
import 'package:pixiv_func/app/theme/replica_theme.dart';
import 'package:pixiv_func/app/widgets/author_summary.dart';
import 'package:pixiv_func/app/widgets/feed/feed_states.dart';
import 'package:pixiv_func/app/widgets/replica_scaffold.dart';
import 'package:pixiv_func/app/widgets/tag_chips.dart';

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
    expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);
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
