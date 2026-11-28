import 'dart:typed_data';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/theme/forui_theme_bridge.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/func_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/theme/system_colors.dart';
import 'package:parfait/app/widgets/ambient_wash.dart';
import 'support/contrast.dart';

List<double> _applyAmbient(List<double> matrix, List<double> rgb) => [
  for (var k = 0; k < 3; k++)
    (matrix[k * 5] * rgb[0] * 255 +
            matrix[k * 5 + 1] * rgb[1] * 255 +
            matrix[k * 5 + 2] * rgb[2] * 255 +
            matrix[k * 5 + 4]) /
        255,
];

double _ambientLuma(List<double> rgb) =>
    0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];

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
          expect(fTheme.typography.body.fontFamily, isNot('system-ui'));
          expect(fTheme.typography.display.fontFamily, isNot('system-ui'));
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

    test(
      'platformFontFamilyFallback resolves Windows and Linux locale chains without touching mobile or macOS',
      () {
        for (final platform in [
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.macOS,
        ]) {
          for (final locale in const [
            Locale('zh', 'CN'),
            Locale('ja', 'JP'),
            Locale('en', 'US'),
            null,
          ]) {
            expect(
              platformFontFamilyFallback(platform, locale: locale),
              isNull,
            );
          }
        }

        final winZh = platformFontFamilyFallback(
          TargetPlatform.windows,
          locale: const Locale('zh', 'CN'),
        )!;
        expect(winZh, isNot(contains('SimSun')));
        expect(
          winZh.indexOf('Microsoft YaHei UI'),
          lessThan(winZh.indexOf('Yu Gothic UI')),
        );

        final winJa = platformFontFamilyFallback(
          TargetPlatform.windows,
          locale: const Locale('ja', 'JP'),
        )!;
        expect(
          winJa.indexOf('Yu Gothic UI'),
          lessThan(winJa.indexOf('Microsoft YaHei UI')),
        );

        final linuxZh = platformFontFamilyFallback(
          TargetPlatform.linux,
          locale: const Locale('zh', 'CN'),
        )!;
        expect(
          linuxZh.indexOf('Noto Sans CJK SC'),
          lessThan(linuxZh.indexOf('Noto Sans CJK JP')),
        );

        final linuxJa = platformFontFamilyFallback(
          TargetPlatform.linux,
          locale: const Locale('ja', 'JP'),
        )!;
        expect(
          linuxJa.indexOf('Noto Sans CJK JP'),
          lessThan(linuxJa.indexOf('Noto Sans CJK SC')),
        );

        final winTheme = replicaTheme(
          Brightness.light,
          platform: TargetPlatform.windows,
          locale: const Locale('zh', 'CN'),
        );
        final tokens = winTheme.extension<FuncSemanticTokens>()!;
        expect(winTheme.textTheme.bodyMedium?.fontFamily, 'Segoe UI');
        expect(winTheme.textTheme.bodyMedium?.fontFamilyFallback, winZh);
        expect(tokens.body.fontFamily, 'Segoe UI');
        expect(tokens.body.fontFamilyFallback, winZh);
        expect(tokens.title.fontFamily, 'Segoe UI');

        final winForui = foruiThemeFrom(winTheme, touch: false);
        expect(winForui.typography.body.fontFamily, 'Segoe UI');
        expect(winForui.typography.body.fontFamilyFallback, winZh);
        expect(winForui.typography.body.sm.fontFamilyFallback, winZh);

        // Explicit fallback override (e.g. layout test harness) always wins.
        const custom = ['TestFallback'];
        final overridden = replicaTheme(
          Brightness.light,
          platform: TargetPlatform.linux,
          locale: const Locale('zh', 'CN'),
          fontFamilyFallback: custom,
        );
        expect(overridden.textTheme.bodyMedium?.fontFamilyFallback, custom);

        // Even a ThemeData with a null bodyMedium fontFamily never emits CSS
        // 'system-ui' through the Forui bridge.
        final bareTheme = ThemeData(
          platform: TargetPlatform.linux,
          textTheme: const TextTheme(bodyMedium: TextStyle(fontSize: 14)),
        );
        final bareForui = foruiThemeFrom(bareTheme, touch: false);
        expect(bareForui.typography.body.fontFamily, isNot('system-ui'));
        expect(bareForui.typography.body.fontFamily, isNotEmpty);
      },
    );
  });

  group('AmbientWash', () {
    test(
      'ambient light keeps the page lightness and a share of the colour',
      () {
        for (final (brightness, chroma, lift) in [
          (Brightness.light, 0.4, -0.03),
          (Brightness.dark, 0.6, 0.07),
        ]) {
          final theme = replicaTheme(brightness);
          final matrix = AmbientTone.matrixOf(theme);
          final page = theme.colorScheme.surface;
          final washed = [page.r + lift, page.g + lift, page.b + lift];

          for (final grey in [1.0, 0.5, 0.0]) {
            final out = _applyAmbient(matrix, [grey, grey, grey]);
            for (var k = 0; k < 3; k++) {
              expect(out[k], closeTo(washed[k], 1e-9), reason: '$brightness');
            }
          }
          for (final colour in [
            [0.9, 0.1, 0.2],
            [0.24, 0.55, 0.55],
            [0.1, 0.2, 0.9],
          ]) {
            final out = _applyAmbient(matrix, colour);
            expect(_ambientLuma(out), closeTo(_ambientLuma(washed), 1e-9));
            for (final k in [0, 2]) {
              expect(
                out[k] - out[1],
                closeTo(
                  chroma * (colour[k] - colour[1]) + washed[k] - washed[1],
                  1e-9,
                ),
              );
            }
          }
        }
      },
    );
  });
}
