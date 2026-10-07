import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/author_summary.dart';
import 'package:parfait/app/widgets/feed/feed_states.dart';
import 'package:parfait/app/widgets/tag_chips.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

/// Component-level visual matrix: light/dark x key states for the shared
/// widgets every page family consumes. Text renders with the deterministic
/// test font, so these files are stable across machines; icon glyphs in the
/// bar golden come from the bundled iconFont loaded in icon_font_test.dart.
void main() {
  Future<void> pumpGolden(
    WidgetTester tester,
    Widget child, {
    required Brightness brightness,
    Size size = const Size(360, 260),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: replicaTheme(brightness),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: Center(child: child)),
        ),
      ),
    );
    await tester.pump();
  }

  for (final brightness in Brightness.values) {
    final tone = brightness == Brightness.light ? 'light' : 'dark';

    testWidgets('feed empty state ($tone)', (tester) async {
      await pumpGolden(
        tester,
        FeedEmpty(
          icon: Icons.inbox_outlined,
          title: 'Nothing here yet',
          detail: 'A detail line explains why.',
          onRefresh: () async {},
          retryLabel: 'Retry',
        ),
        brightness: brightness,
      );
      // Empty and error states fade in when they appear.
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/feed_empty_$tone.png'),
      );
    });

    testWidgets('feed error state ($tone)', (tester) async {
      await pumpGolden(
        tester,
        FeedError(
          title: 'Failed to load',
          error: 'SocketException: broken',
          retryLabel: 'Retry',
          onRetry: () {},
        ),
        brightness: brightness,
      );
      // Empty and error states fade in when they appear.
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/feed_error_$tone.png'),
      );
    });

    testWidgets('feed loading state ($tone)', (tester) async {
      await pumpGolden(
        tester,
        const FeedLoading(label: 'Loading feed'),
        brightness: brightness,
        size: const Size(360, 120),
      );
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/feed_loading_$tone.png'),
      );
    });

    testWidgets('tag chips ($tone)', (tester) async {
      await pumpGolden(
        tester,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TagChip(label: 'cat', onTap: () {}),
            TagChip(label: 'girl', translated: '女の子', onTap: () {}),
            TagChip(label: 'r18', blockMode: true, blocked: true, onTap: () {}),
          ],
        ),
        brightness: brightness,
        size: const Size(360, 90),
      );
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/tag_chips_$tone.png'),
      );
    });

    testWidgets('author summary ($tone)', (tester) async {
      await pumpGolden(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AuthorSummary(
              name: 'An Author With A Rather Long Name',
              account: 'author_account',
              imageUrl: null,
              onTap: () {},
            ),
            const SizedBox(height: 16),
            AuthorSummary(
              name: 'Compact Author',
              imageUrl: null,
              compact: true,
              onTap: () {},
            ),
          ],
        ),
        brightness: brightness,
        size: const Size(360, 140),
      );
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/author_summary_$tone.png'),
      );
    });
  }
}
