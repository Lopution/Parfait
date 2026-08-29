import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/app/icons/app_icons.dart';
import 'package:pixiv_func/core/platform/android_intent_channel.dart';
import 'package:pixiv_func/core/platform/intent_router.dart';
import 'package:pixiv_func/features/home/home_page.dart';

/// The icon font tests render the real [HomePage] shell, which subscribes to
/// the Android intent bridge in `initState`. This stub replaces only that
/// external platform boundary; everything else under test stays real.
class _NoAndroidIntentSource implements AndroidIntentSource {
  const _NoAndroidIntentSource();

  @override
  Future<AndroidIntentResult> readInitial() async =>
      const IgnoredAndroidIntent('test: no android intent source');

  @override
  Stream<AndroidIntentResult> get onNewIntent => const Stream.empty();
}

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
      0xe900: 'addFollow',
      0xe901: 'filter',
      0xe902: 'follow',
      0xe903: 'home',
      0xe904: 'me',
      0xe905: 'n',
      0xe906: 'ranking',
      0xe907: 'search',
      0xe908: 'toggle',
      0xe909: 'pawoo',
      0xe90a: 'twitter',
      0xe90b: 'web',
      0xe90c: 'friend',
      0xe90d: 'blocked',
    };
    for (final entry in expected.entries) {
      // Each declared icon must keep its beta56 codepoint.
      switch (entry.value) {
        case 'addFollow':
          expect(AppIcons.addFollow.codePoint, entry.key);
        case 'filter':
          expect(AppIcons.filter.codePoint, entry.key);
        case 'follow':
          expect(AppIcons.follow.codePoint, entry.key);
        case 'home':
          expect(AppIcons.home.codePoint, entry.key);
        case 'me':
          expect(AppIcons.me.codePoint, entry.key);
        case 'n':
          expect(AppIcons.n.codePoint, entry.key);
        case 'ranking':
          expect(AppIcons.ranking.codePoint, entry.key);
        case 'search':
          expect(AppIcons.search.codePoint, entry.key);
        case 'toggle':
          expect(AppIcons.toggle.codePoint, entry.key);
        case 'pawoo':
          expect(AppIcons.pawoo.codePoint, entry.key);
        case 'twitter':
          expect(AppIcons.twitter.codePoint, entry.key);
        case 'web':
          expect(AppIcons.web.codePoint, entry.key);
        case 'friend':
          expect(AppIcons.friend.codePoint, entry.key);
        case 'blocked':
          expect(AppIcons.blocked.codePoint, entry.key);
      }
    }
  });

  testWidgets('home bar renders four iconFont icons plus Icons.settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: HomePage(intentSource: _NoAndroidIntentSource()),
        ),
      ),
    );
    // The recommended tab starts its async load; settle the shell first.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final iconWidgets = tester
        .widgetList<Icon>(
          find.descendant(
            of: find.byType(BottomAppBar),
            matching: find.byType(Icon),
          ),
        )
        .toList();
    expect(iconWidgets, hasLength(5));

    for (var i = 0; i < 4; i++) {
      expect(iconWidgets[i].icon!.fontFamily, 'iconFont');
      expect(iconWidgets[i].icon!.matchTextDirection, isTrue);
    }
    // The fifth tab keeps the Material settings icon in the original app.
    expect(identical(iconWidgets[4].icon, Icons.settings), isTrue);
  });

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

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: HomePage(intentSource: _NoAndroidIntentSource()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(
      find.byType(BottomAppBar),
      matchesGoldenFile('goldens/home_bar.png'),
    );
  });
}
