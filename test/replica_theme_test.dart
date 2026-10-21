import 'dart:typed_data';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/func_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/theme/system_colors.dart';
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

  test('the light accent reads at 4.5:1 up to the sheet tier', () {
    final scheme = replicaTheme(Brightness.light).colorScheme;
    // Dialogs and the highest tier fall short: a known trade (THEME-06).
    for (final background in _surfaces(scheme).take(4)) {
      expect(
        contrastRatio(scheme.primary, background),
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

  test('a disabled switch that is on takes no accent', () {
    const lockedOn = {WidgetState.selected, WidgetState.disabled};
    for (final brightness in Brightness.values) {
      final theme = replicaTheme(brightness);
      expect(
        theme.switchTheme.trackColor!.resolve(lockedOn),
        isNot(theme.colorScheme.primary),
      );
    }
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
      final tokens = theme.extension<FuncSemanticTokens>()!;
      expect(tokens.brand, system.primary);
      expect(tokens.onBrand, system.onPrimary);
      expect(
        theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
        system.primary,
      );
      expect(theme.appBarTheme.backgroundColor, theme.scaffoldBackgroundColor);
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
  });
}
