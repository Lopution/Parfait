import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/app/icons/app_icons.dart';
import 'package:pixiv_func/app/navigation/routes.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/app/widgets/func_bottom_nav.dart';

void main() {
  group('iconFont asset registration', () {
    test('assets/icon.ttf is bundled and non-empty', () async {
      final data = await rootBundle.load('assets/icon.ttf');
      expect(data.lengthInBytes, greaterThan(0));
    });

    test(
      'pubspec registers the iconFont family pointing at assets/icon.ttf',
      () {
        final pubspec = File('pubspec.yaml').readAsStringSync();
        expect(pubspec.contains('family: iconFont'), isTrue);
        expect(
          pubspec.contains('asset: assets/icon.ttf'),
          isTrue,
          reason: 'pubspec.yaml must declare assets/icon.ttf under fonts',
        );
      },
    );
  });

  test('AppIcons use the iconFont family with beta56 codepoints', () {
    const expected = <int, String>{
      0xe902: 'follow',
      0xe903: 'home',
      0xe905: 'n',
      0xe906: 'ranking',
      0xe907: 'search',
      0xe90c: 'friend',
    };
    for (final entry in expected.entries) {
      // Each declared icon must keep its beta56 codepoint.
      switch (entry.value) {
        case 'follow':
          expect(AppIcons.follow.codePoint, entry.key);
        case 'home':
          expect(AppIcons.home.codePoint, entry.key);
        case 'n':
          expect(AppIcons.n.codePoint, entry.key);
        case 'ranking':
          expect(AppIcons.ranking.codePoint, entry.key);
        case 'search':
          expect(AppIcons.search.codePoint, entry.key);
        case 'friend':
          expect(AppIcons.friend.codePoint, entry.key);
      }
    }
  });

  testWidgets(
    'home bar renders four iconFont icons plus the settings tab icon',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            routerConfig: createPixivRouter(initialLocation: '/recommended'),
          ),
        ),
      );
      // The recommended tab starts its async load; settle the shell first.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final iconWidgets = tester
          .widgetList<Icon>(
            find.descendant(
              of: find.byType(FuncBottomNav),
              matching: find.byType(Icon),
            ),
          )
          .toList();
      expect(iconWidgets, hasLength(5));

      // Four destinations use the bundled beta56 iconFont — the prominent
      // center circle included — while settings stays a Material icon.
      final bundled = iconWidgets
          .where((w) => w.icon!.fontFamily == 'iconFont')
          .toList();
      expect(bundled, hasLength(4));
      for (final icon in bundled) {
        expect(icon.icon!.matchTextDirection, isTrue);
      }
      expect(
        iconWidgets.any((w) => identical(w.icon, Icons.settings_outlined)),
        isTrue,
      );
    },
  );

  testWidgets('home bar renders real glyphs from the bundled font', (
    tester,
  ) async {
    // Load the actual beta56 font binary so glyphs come from assets/icon.ttf,
    // making the golden below an observable anti-tofu render check.
    final fontData = File(
      'assets/icon.ttf',
    ).readAsBytesSync().buffer.asByteData();
    final loader = FontLoader('iconFont')..addFont(Future.value(fontData));
    await loader.load();

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh', 'CN'),
          routerConfig: createPixivRouter(initialLocation: '/recommended'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(
      find.byType(FuncBottomNav),
      matchesGoldenFile('goldens/home_bar.png'),
    );
  });
}
