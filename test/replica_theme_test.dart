import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pixiv_func/app/theme/func_semantic_tokens.dart';
import 'package:pixiv_func/app/theme/func_tokens.dart';
import 'package:pixiv_func/app/theme/replica_theme.dart';
import 'package:pixiv_func/app/widgets/replica_switch_tile.dart';

void main() {
  test('light and dark themes own the Material 3 component tokens', () {
    final light = replicaTheme(Brightness.light);
    final dark = replicaTheme(Brightness.dark);

    for (final theme in [light, dark]) {
      expect(theme.useMaterial3, isTrue);
      expect(theme.colorScheme.primary, FuncTokens.primary);
      expect(theme.navigationBarTheme.indicatorColor, isNotNull);
      expect(theme.cardTheme.shape, isA<RoundedRectangleBorder>());
      expect(theme.chipTheme.shape, isA<RoundedRectangleBorder>());
      expect(theme.dialogTheme.shape, isA<RoundedRectangleBorder>());
      expect(theme.bottomSheetTheme.shape, isA<RoundedRectangleBorder>());
      expect(theme.snackBarTheme.behavior, SnackBarBehavior.floating);
      expect(theme.switchTheme.trackColor, isNotNull);
    }
  });

  test('semantic tokens layer is wired and un-flattens raised surfaces', () {
    final light = replicaTheme(Brightness.light);
    final dark = replicaTheme(Brightness.dark);

    final lightTokens = light.extension<FuncSemanticTokens>();
    final darkTokens = dark.extension<FuncSemanticTokens>();
    expect(lightTokens, isNotNull);
    expect(darkTokens, isNotNull);

    // Brand constants stay owned by FuncTokens — the extension references
    // them rather than restating literals.
    expect(lightTokens!.brand, FuncTokens.primary);
    expect(lightTokens.contentPrimary, FuncTokens.lightText);
    expect(darkTokens!.contentPrimary, FuncTokens.darkText);

    // Raised surfaces are no longer flattened onto the base surface.
    expect(
      light.colorScheme.surfaceContainerHigh,
      isNot(light.colorScheme.surfaceContainer),
    );
    expect(
      dark.colorScheme.surfaceContainerHigh,
      isNot(dark.colorScheme.surfaceContainer),
    );
    expect(lightTokens.surfaceRaised, FuncTokens.lightSurfaceRaised);
    expect(darkTokens.surfaceRaised, FuncTokens.darkSurfaceRaised);
  });

  testWidgets('selected states are pinned to primaryContainer', (tester) async {
    for (final brightness in Brightness.values) {
      final theme = replicaTheme(brightness);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Column(
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('S1')),
                    ButtonSegment(value: 1, label: Text('S2')),
                  ],
                  selected: const {0},
                  onSelectionChanged: (_) {},
                ),
                SizedBox(
                  width: 120,
                  height: 200,
                  child: NavigationRail(
                    selectedIndex: 0,
                    onDestinationSelected: (_) {},
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.add),
                        label: Text('R1'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.remove),
                        label: Text('R2'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      // Swapping the app's theme runs through AnimatedTheme — let the
      // transition finish before reading themed colors.
      await tester.pumpAndSettle();

      // The segment's painted surface is the innermost Material above its
      // label — that is what the resolved backgroundColor lands on.
      final segmentSurface = tester.widget<Material>(
        find
            .ancestor(of: find.text('S1'), matching: find.byType(Material))
            .first,
      );
      expect(segmentSurface.color, theme.colorScheme.primaryContainer);

      // Every destination builds its indicator; the unselected one is
      // collapsed by its animation but carries the same themed color.
      final indicators = tester.widgetList<NavigationIndicator>(
        find.byType(NavigationIndicator),
      );
      expect(indicators, isNotEmpty);
      for (final indicator in indicators) {
        expect(indicator.color, theme.colorScheme.primaryContainer);
      }
    }
  });

  testWidgets('ReplicaSwitchTile uses the Material 3 Switch', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: replicaTheme(Brightness.light),
        home: Scaffold(
          body: ReplicaSwitchTile(
            value: true,
            title: const Text('Theme'),
            onTap: () {},
          ),
        ),
      ),
    );

    expect(find.byType(Switch), findsOneWidget);
  });
}
