import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pixiv_func/app/motion/motion_tokens.dart';
import 'package:pixiv_func/app/theme/replica_theme.dart';
import 'package:pixiv_func/app/widgets/feed/feed_states.dart';
import 'package:pixiv_func/app/widgets/replica_scaffold.dart';

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
