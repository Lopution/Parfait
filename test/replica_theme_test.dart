import 'dart:typed_data';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/theme/forui_theme_bridge.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/func_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/theme/system_colors.dart';
import 'helpers/localized_app.dart';
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

  test('text on the error fill reads at 4.5:1 in both themes', () {
    for (final brightness in Brightness.values) {
      final scheme = replicaTheme(brightness).colorScheme;
      expect(
        contrastRatio(scheme.onError, scheme.error),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('the accent reads at 4.5:1 up to the sheet tier, on dark on all', () {
    final light = replicaTheme(Brightness.light).colorScheme;
    // Dialogs and the highest tier fall short: a known trade (THEME-06).
    for (final background in _surfaces(light).take(4)) {
      expect(
        contrastRatio(light.primary, background),
        greaterThanOrEqualTo(4.5),
      );
    }
    final dark = replicaTheme(Brightness.dark).colorScheme;
    for (final background in _surfaces(dark)) {
      expect(
        contrastRatio(dark.primary, background),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('selection and the snackbar action read at 4.5:1 in both themes', () {
    for (final brightness in Brightness.values) {
      final scheme = replicaTheme(brightness).colorScheme;
      expect(
        contrastRatio(scheme.onPrimaryContainer, scheme.primaryContainer),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(scheme.inversePrimary, scheme.inverseSurface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(scheme.onInverseSurface, scheme.inverseSurface),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('fills are the brand pink under white; selection stays tonal', () {
    for (final brightness in Brightness.values) {
      final theme = replicaTheme(brightness);
      final tokens = theme.extension<FuncSemanticTokens>()!;
      final filled = theme.filledButtonTheme.style!;
      expect(tokens.brand, FuncTokens.primary);
      expect(filled.backgroundColor!.resolve({}), tokens.brand);
      expect(filled.foregroundColor!.resolve({}), FuncTokens.white);
      expect(
        filled.backgroundColor!.resolve({WidgetState.disabled}),
        isNot(tokens.brand),
      );
      // A selected row is a pale container under dark text, not the fill.
      expect(theme.colorScheme.primaryContainer, isNot(tokens.brand));
    }
  });

  test('header tokens use clean canvas and keep >= 4.5:1 contrast', () {
    for (final brightness in Brightness.values) {
      for (final systemColors in [
        null,
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: brightness,
        ),
        ColorScheme.fromSeed(
          seedColor: const Color(0xFFFFB300),
          brightness: brightness,
        ),
      ]) {
        final theme = replicaTheme(brightness, systemColors: systemColors);
        final tokens = theme.extension<FuncSemanticTokens>()!;
        final surface = tokens.brandedHeaderSurface;
        expect(surface, tokens.canvas);
        expect(tokens.brandedHeaderForeground, theme.colorScheme.onSurface);
        expect(
          tokens.brandedHeaderTabUnselected,
          theme.colorScheme.onSurfaceVariant,
        );
        final selectedTab = theme.colorScheme.primary;
        expect(
          contrastRatio(tokens.brandedHeaderForeground, surface),
          greaterThanOrEqualTo(4.5),
          reason: '$brightness brandedHeaderForeground on $surface',
        );
        expect(
          contrastRatio(selectedTab, surface),
          greaterThanOrEqualTo(4.5),
          reason: '$brightness selected tab on $surface',
        );
        expect(
          contrastRatio(tokens.brandedHeaderTabUnselected, surface),
          greaterThanOrEqualTo(4.5),
          reason: '$brightness brandedHeaderTabUnselected on $surface',
        );
      }
    }
  });

  test(
    'overlays and progress indicators share brandHairline across themes',
    () {
      Color borderColor(ShapeBorder? s) =>
          (s! as RoundedRectangleBorder).side.color;
      for (final brightness in Brightness.values) {
        final theme = replicaTheme(brightness);
        final tokens = theme.extension<FuncSemanticTokens>()!;
        for (final color in [
          borderColor(theme.dialogTheme.shape),
          borderColor(theme.bottomSheetTheme.shape),
          theme.menuTheme.style!.side!.resolve({})!.color,
          borderColor(theme.popupMenuTheme.shape),
          theme.progressIndicatorTheme.linearTrackColor,
          theme.progressIndicatorTheme.circularTrackColor,
        ]) {
          expect(color, tokens.brandHairline);
        }
        expect(theme.progressIndicatorTheme.strokeCap, StrokeCap.round);
      }
    },
  );

  testWidgets(
    'replicaTheme provides visible pressed state feedback for InkWell, ListTile, and buttons',
    (tester) async {
      for (final brightness in Brightness.values) {
        final theme = replicaTheme(brightness);
        expect(theme.highlightColor, isNot(FuncTokens.transparent));
        expect(theme.highlightColor.a, greaterThanOrEqualTo(0.08));
        expect(theme.hoverColor.a, greaterThan(0));
        expect(theme.focusColor.a, greaterThan(0));

        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Column(
                children: [
                  InkWell(
                    onTap: () {},
                    child: const SizedBox(height: 48, width: 200),
                  ),
                  ListTile(title: const Text('tile'), onTap: () {}),
                  FilledButton(onPressed: () {}, child: const Text('button')),
                ],
              ),
            ),
          ),
        );

        Future<void> expectPressedRect(Finder target) async {
          final gesture = await tester.startGesture(tester.getCenter(target));
          try {
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 220));
            final material = tester.renderObject(
              find.ancestor(of: target, matching: find.byType(Material)).first,
            );
            expect(
              material,
              paints..something((symbol, arguments) {
                if (symbol != #drawRect && symbol != #drawRRect) return false;
                final color = (arguments[1] as Paint).color;
                return color.a >= 0.06 && color.a <= 0.20;
              }),
            );
          } finally {
            await gesture.up();
            await tester.pumpAndSettle();
          }
        }

        await expectPressedRect(find.byType(InkWell).first);
        await expectPressedRect(find.byType(ListTile));
        await expectPressedRect(find.byType(FilledButton));
      }
    },
  );

  test('a disabled switch that is on takes no accent', () {
    final lockedOn = {FSwitchVariant.selected, FSwitchVariant.disabled};
    for (final brightness in Brightness.values) {
      final theme = replicaTheme(brightness);
      final forui = foruiThemeFrom(theme, touch: false);
      expect(
        forui.switchStyle.trackColor.resolve(lockedOn),
        isNot(theme.colorScheme.primary),
      );
    }
  });

  test(
    'a system palette drives accent, surface ladder, and semantic tokens',
    () {
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
        // Dynamic color drives the full surface ladder and neutral roles so
        // wallpaper tinting reaches canvases, bars, cards, and controls.
        expect(_surfaces(scheme), _surfaces(system));
        expect(_surfaces(scheme), isNot(_surfaces(base.colorScheme)));
        expect(scheme.onSurface, system.onSurface);
        expect(scheme.onSurfaceVariant, system.onSurfaceVariant);
        expect(scheme.secondary, system.secondary);
        expect(scheme.secondaryContainer, system.secondaryContainer);
        // Every pink-by-default slot follows the scheme.
        expect(theme.primaryColor, system.primary);
        expect(theme.tabBarTheme.labelColor, system.primary);
        expect(theme.tabBarTheme.indicatorColor, system.primary);
        final tokens = theme.extension<FuncSemanticTokens>()!;
        expect(tokens.brand, system.primary);
        expect(tokens.onBrand, system.onPrimary);
        expect(tokens.canvas, system.surface);
        expect(tokens.surface, system.surfaceContainer);
        expect(tokens.surfaceRaised, system.surfaceContainerHigh);
        expect(
          theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
          system.primary,
        );
        expect(
          theme.appBarTheme.backgroundColor,
          theme.scaffoldBackgroundColor,
        );
      }
    },
  );

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
      final container = ProviderContainer.test();
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

    test(
      'a platform without a dynamic colour plugin has no system colours',
      () async {
        // With no mock handler registered, the channel throws
        // MissingPluginException and the provider reads it as "no palette".
        expect(await read(), isNull);
      },
    );
  });

  group('Forui theme bridge', () {
    test(
      'foruiThemeFrom bridges colors, hairlines, haptics, and keeps platform font',
      () {
        final dynamicScheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFF006D77),
          brightness: Brightness.light,
        );
        for (final (brightness, scheme) in [
          (Brightness.light, null),
          (Brightness.dark, null),
          (Brightness.light, dynamicScheme),
        ]) {
          final material = replicaTheme(brightness, systemColors: scheme);
          final fTheme = foruiThemeFrom(material, touch: true);
          final tokens = material.extension<FuncSemanticTokens>()!;

          expect(fTheme.colors.brightness, brightness);
          expect(fTheme.colors.primary, material.colorScheme.primary);
          expect(fTheme.colors.border, tokens.brandHairline);
          expect(fTheme.hapticFeedback, const FHapticFeedback.none());

          final expectedFamily = material.textTheme.bodyMedium?.fontFamily;
          for (final face in [
            fTheme.typography.display,
            fTheme.typography.body,
          ]) {
            for (final style in [
              face.xs3,
              face.xs2,
              face.xs,
              face.sm,
              face.md,
              face.lg,
              face.xl,
              face.xl2,
              face.xl3,
              face.xl4,
              face.xl5,
              face.xl6,
              face.xl7,
              face.xl8,
            ]) {
              expect(style.fontFamily, expectedFamily);
              expect(style.fontFamily, isNot('packages/forui/Inter'));
            }
          }
        }
      },
    );

    testWidgets(
      'ForuiThemeHost forwards MotionScope reduce to FAccessibilityMotion.disabled',
      (tester) async {
        FAccessibilityMotion? captured;
        Widget probe(bool reduce) => localizedApp(
          body: MotionScope(
            reduce: reduce,
            child: ForuiThemeHost(
              child: Builder(
                builder: (context) {
                  captured = FAccessibilityScope.motionOf(context);
                  return const SizedBox();
                },
              ),
            ),
          ),
        );

        await tester.pumpWidget(probe(true));
        expect(captured, FAccessibilityMotion.disabled);

        await tester.pumpWidget(probe(false));
        expect(captured, FAccessibilityMotion.all);
      },
    );

    testWidgets(
      'replicaTheme compares equal across calls and ForuiThemeHost caches across unrelated rebuilds',
      (tester) async {
        for (final brightness in Brightness.values) {
          expect(replicaTheme(brightness), replicaTheme(brightness));
          final sys = ColorScheme.fromSeed(
            seedColor: const Color(0xFF2E7D32),
            brightness: brightness,
          );
          expect(
            replicaTheme(brightness, systemColors: sys),
            replicaTheme(brightness, systemColors: sys),
          );
        }

        final seen = <FThemeData>[];
        final tick = ValueNotifier<int>(0);
        addTearDown(tick.dispose);
        await tester.pumpWidget(
          localizedApp(
            theme: replicaTheme(Brightness.light),
            body: ValueListenableBuilder<int>(
              valueListenable: tick,
              builder: (_, _, _) => ForuiThemeHost(
                child: Builder(
                  builder: (context) {
                    seen.add(context.theme);
                    return const SizedBox();
                  },
                ),
              ),
            ),
          ),
        );
        tick.value = 1;
        await tester.pump();
        expect(seen, hasLength(2));
        expect(identical(seen[0], seen[1]), isTrue);
      },
    );
  });
}
