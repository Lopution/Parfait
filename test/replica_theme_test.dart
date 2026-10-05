import 'dart:typed_data';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/func_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/theme/system_colors.dart';
import 'package:parfait/app/widgets/replica_switch_tile.dart';
import 'support/contrast.dart';

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
          contrastRatio(scheme.onSurface, background),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrastRatio(scheme.onSurfaceVariant, background),
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
        contrastRatio(snackBar.contentTextStyle!.color!, background),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(snackBar.actionTextColor!, background),
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

  testWidgets('the app bar steps to surfaceContainer under scrolled content', (
    tester,
  ) async {
    Color appBarColor() => tester
        .widget<Material>(
          find
              .descendant(
                of: find.byType(AppBar),
                matching: find.byType(Material),
              )
              .first,
        )
        .color!;

    for (final brightness in Brightness.values) {
      final theme = replicaTheme(brightness);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            appBar: AppBar(title: const Text('App bar')),
            body: ListView(
              children: [for (var i = 0; i < 40; i++) Text('row $i')],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(appBarColor(), theme.scaffoldBackgroundColor);

      // Content scrolled under the bar: the theme's backgroundColor is a
      // WidgetStateColor, so the bar reads surfaceContainer — the M3
      // scrolled-under step — with no elevation change.
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(appBarColor(), theme.colorScheme.surfaceContainer);
      expect(theme.appBarTheme.scrolledUnderElevation, 0);

      await tester.drag(find.byType(ListView), const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(appBarColor(), theme.scaffoldBackgroundColor);
    }
  });

  testWidgets('component text styles resolve through the themed textTheme', (
    tester,
  ) async {
    TextStyle? paragraphStyle(String text) {
      return tester.renderObject<RenderParagraph>(find.text(text)).text.style;
    }

    void expectStyle(
      TextStyle? style, {
      required double fontSize,
      required FontWeight weight,
    }) {
      // No bundled family: the platform default (Roboto) carries Latin
      // and digits.
      expect(style?.fontFamily, 'Roboto');
      expect(style?.fontSize, fontSize);
      expect(style?.fontWeight, weight);
    }

    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: replicaTheme(brightness),
          home: Scaffold(
            appBar: AppBar(title: const Text('App bar')),
            body: Column(
              children: [
                FilterChip(label: const Text('chip'), onSelected: (_) {}),
                SizedBox(
                  width: 120,
                  height: 160,
                  child: NavigationRail(
                    selectedIndex: 0,
                    onDestinationSelected: (_) {},
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.add),
                        label: Text('rail'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.remove),
                        label: Text('other'),
                      ),
                    ],
                  ),
                ),
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () => ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('snack'))),
                    child: const Text('toast'),
                  ),
                ),
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => const AlertDialog(
                        title: Text('dialog title'),
                        content: Text('dialog content'),
                      ),
                    ),
                    child: const Text('dialog'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      // Let AnimatedTheme converge when the second iteration swaps themes.
      await tester.pumpAndSettle();

      // AppBar title keeps 16, now on the w600 title role.
      expectStyle(
        paragraphStyle('App bar'),
        fontSize: 16,
        weight: FontWeight.w600,
      );
      // Chip label keeps 14/w400.
      expectStyle(
        paragraphStyle('chip'),
        fontSize: 14,
        weight: FontWeight.w400,
      );
      // Rail labels derive from labelMedium + a themed color — the slot is
      // geometry-less in material_ui's color-only default textTheme, so only
      // the family and color are pinned here.
      final railStyle = paragraphStyle('rail');
      expect(railStyle?.fontFamily, 'Roboto');
      expect(railStyle?.color, replicaTheme(brightness).colorScheme.primary);

      await tester.tap(find.text('toast'));
      await tester.pumpAndSettle();
      expectStyle(
        paragraphStyle('snack'),
        fontSize: 14,
        weight: FontWeight.w400,
      );
      ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold)),
      ).hideCurrentSnackBar();
      await tester.pumpAndSettle();

      await tester.tap(find.text('dialog'));
      await tester.pumpAndSettle();
      expectStyle(
        paragraphStyle('dialog title'),
        fontSize: 24,
        weight: FontWeight.w500,
      );
      expectStyle(
        paragraphStyle('dialog content'),
        fontSize: 14,
        weight: FontWeight.w400,
      );
      // Tap the barrier to dismiss (showDialog's default barrierDismissible).
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }
  });

  test('one type scale feeds TextTheme roles and semantic tokens', () {
    void expectStyle(
      TextStyle? style, {
      required double fontSize,
      required FontWeight weight,
    }) {
      expect(style?.fontSize, fontSize);
      expect(style?.fontWeight, weight);
    }

    for (final brightness in Brightness.values) {
      final theme = replicaTheme(brightness);
      final textTheme = theme.textTheme;

      expectStyle(textTheme.titleLarge, fontSize: 20, weight: FontWeight.w600);
      expectStyle(textTheme.titleMedium, fontSize: 16, weight: FontWeight.w600);
      expectStyle(textTheme.titleSmall, fontSize: 14, weight: FontWeight.w500);
      expectStyle(textTheme.bodyLarge, fontSize: 14, weight: FontWeight.w500);
      expectStyle(textTheme.bodyMedium, fontSize: 14, weight: FontWeight.w400);
      expectStyle(textTheme.bodySmall, fontSize: 12, weight: FontWeight.w400);
      expectStyle(textTheme.labelLarge, fontSize: 14, weight: FontWeight.w500);
      expectStyle(textTheme.labelSmall, fontSize: 11, weight: FontWeight.w500);
      expectStyle(
        textTheme.headlineSmall,
        fontSize: 18,
        weight: FontWeight.w500,
      );

      // Every semantic type slot resolves to its TextTheme role (size and
      // weight); only colors and tabular figures diverge by design.
      final tokens = theme.extension<FuncSemanticTokens>()!;
      final roles = <(TextStyle, TextStyle?)>{
        (tokens.display, textTheme.titleLarge),
        (tokens.title, textTheme.titleMedium),
        (tokens.body, textTheme.bodyMedium),
        (tokens.label, textTheme.labelLarge),
        (tokens.caption, textTheme.bodySmall),
        (tokens.numeric, textTheme.labelLarge),
      };
      for (final (token, role) in roles) {
        expect(token.fontSize, role?.fontSize);
        expect(token.fontWeight, role?.fontWeight);
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

  test('a system palette replaces only the accent roles', () {
    for (final brightness in Brightness.values) {
      final system = ColorScheme.fromSeed(
        seedColor: const Color(0xFF2E7D32),
        brightness: brightness,
      );
      final base = replicaTheme(brightness);
      final theme = replicaTheme(brightness, systemColors: system);
      final scheme = theme.colorScheme;

      expect(scheme.primary, system.primary);
      expect(scheme.onPrimary, system.onPrimary);
      expect(scheme.primaryContainer, system.primaryContainer);
      expect(scheme.onPrimaryContainer, system.onPrimaryContainer);
      expect(scheme.inversePrimary, system.inversePrimary);
      expect(scheme.surfaceTint, system.surfaceTint);
      // Neutrals keep the app's ladder and text colors.
      expect(_surfaces(scheme), _surfaces(base.colorScheme));
      expect(scheme.onSurface, base.colorScheme.onSurface);
      expect(scheme.secondary, base.colorScheme.secondary);
      // Every pink-by-default slot follows the scheme.
      expect(theme.primaryColor, system.primary);
      expect(theme.tabBarTheme.labelColor, system.primary);
      expect(theme.tabBarTheme.indicatorColor, system.primary);
      expect(theme.extension<FuncSemanticTokens>()!.brand, system.primary);
      expect(theme.appBarTheme.backgroundColor, isA<WidgetStateColor>());
    }
  });

  group('systemColorSchemesProvider', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    void mockPlatform({Int32List? corePalette, int? accent}) {
      messenger.setMockMethodCallHandler(
        DynamicColorPlugin.channel,
        (call) async => switch (call.method) {
          DynamicColorPlugin.methodName => corePalette,
          DynamicColorPlugin.accentColorMethodName => accent,
          _ => null,
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          DynamicColorPlugin.channel,
          null,
        ),
      );
    }

    Future<SystemColorSchemes?> read() {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      return container.read(systemColorSchemesProvider.future);
    }

    test(
      'Android takes tone 40 and tone 80 of the wallpaper palette',
      () async {
        // Five tonal palettes of 13 common tones each; tone 40 is index 4 and
        // tone 80 index 8 of the primary palette.
        final palette = List<int>.generate(
          65,
          (i) => 0xFF000000 | (i * 0x030507),
        );
        // The Android side answers with an IntArray, which decodes as an
        // Int32List; a plain List would decode as List<Object?>.
        mockPlatform(corePalette: Int32List.fromList(palette));

        final schemes = await read();

        expect(schemes!.light.primary, Color(palette[4]));
        expect(schemes.dark.primary, Color(palette[8]));
      },
    );

    test('desktops seed both schemes from the accent color', () async {
      mockPlatform(accent: 0xFF3366CC);

      final schemes = await read();

      const accent = Color(0xFF3366CC);
      expect(
        schemes!.light.primary,
        ColorScheme.fromSeed(seedColor: accent).primary,
      );
      expect(
        schemes.dark.primary,
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
        ).primary,
      );
    });

    test('a platform without either reports no palette', () async {
      mockPlatform();

      expect(await read(), isNull);
    });
  });
}
