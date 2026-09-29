import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pixiv_func/app/theme/func_semantic_tokens.dart';
import 'package:pixiv_func/app/theme/func_tokens.dart';
import 'package:pixiv_func/app/theme/replica_theme.dart';
import 'package:pixiv_func/app/widgets/replica_switch_tile.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

List<Color> _surfaces(ColorScheme scheme) => [
  scheme.surface,
  scheme.surfaceContainerLowest,
  scheme.surfaceContainerLow,
  scheme.surfaceContainer,
  scheme.surfaceContainerHigh,
  scheme.surfaceContainerHighest,
];

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

  test('the surface ladder is monotonic and tiers stay distinct', () {
    for (final brightness in Brightness.values) {
      final theme = replicaTheme(brightness);
      final scheme = theme.colorScheme;
      final dark = brightness == Brightness.dark;

      // The page doubles as the lowest rung; the ladder itself is the five
      // container steps, every adjacent pair visually distinct.
      expect(scheme.surface, scheme.surfaceContainerLowest);
      final ladder = [
        scheme.surfaceContainerLowest,
        scheme.surfaceContainerLow,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
      ];
      for (var i = 0; i < ladder.length - 1; i++) {
        expect(ladder[i], isNot(ladder[i + 1]));
        final lower = ladder[i].computeLuminance();
        final higher = ladder[i + 1].computeLuminance();
        // Light surfaces darken as they rise; dark surfaces lighten.
        expect(higher > lower, dark);
      }

      // The three roles pages choose between must not collapse.
      expect(scheme.surface, isNot(scheme.surfaceContainer));
      expect(scheme.surface, isNot(scheme.surfaceContainerHigh));
      expect(scheme.surfaceContainer, isNot(scheme.surfaceContainerHigh));
      expect(theme.cardColor, scheme.surfaceContainer);

      // The semantic extension follows the ladder: canvas = page,
      // surface = Container, surfaceRaised = High.
      final tokens = theme.extension<FuncSemanticTokens>();
      expect(tokens, isNotNull);
      expect(tokens!.canvas, scheme.surface);
      expect(tokens.surface, scheme.surfaceContainer);
      expect(tokens.surfaceRaised, scheme.surfaceContainerHigh);
      expect(tokens.brand, FuncTokens.primary);
      expect(
        tokens.contentPrimary,
        dark ? FuncTokens.darkText : FuncTokens.lightText,
      );
    }
  });

  test('text stays >= 4.5:1 on every surface tier in both themes', () {
    for (final brightness in Brightness.values) {
      final scheme = replicaTheme(brightness).colorScheme;
      for (final background in _surfaces(scheme)) {
        expect(
          _contrast(scheme.onSurface, background),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(scheme.onSurfaceVariant, background),
          greaterThanOrEqualTo(4.5),
        );
      }
    }
  });

  test('snack bar stands apart from the ladder and stays readable', () {
    for (final brightness in Brightness.values) {
      final theme = replicaTheme(brightness);
      final snackBar = theme.snackBarTheme;
      final background = snackBar.backgroundColor!;
      expect(background, isNot(theme.colorScheme.surface));
      expect(background, isNot(theme.colorScheme.surfaceContainer));
      expect(background, theme.colorScheme.inverseSurface);
      expect(
        _contrast(snackBar.contentTextStyle!.color!, background),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(snackBar.actionTextColor!, background),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('secondary roles are neutral, not brand-derived', () {
    for (final brightness in Brightness.values) {
      final scheme = replicaTheme(brightness).colorScheme;
      expect(HSLColor.fromColor(scheme.secondary).saturation, lessThan(0.1));
      expect(
        HSLColor.fromColor(scheme.secondaryContainer).saturation,
        lessThan(0.1),
      );
    }
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

  testWidgets('a mounted SnackBar paints with the inverted surface', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      final theme = replicaTheme(brightness);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('saved'))),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      );
      // AnimatedTheme lerps between iterations; settle before sampling.
      await tester.pumpAndSettle();

      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();

      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, theme.colorScheme.inverseSurface);
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
