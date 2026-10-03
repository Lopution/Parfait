import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/fit_label.dart';

import '../helpers/locale_layout.dart';

const _en = Locale('en');

/// UI text: these are l10n messages.
const _hint =
    'Applies to every in-app animation; system effects such as '
    'ripples are unaffected';
const _short = 'Page transition';

Future<RenderParagraph> _pumpText(
  WidgetTester tester,
  Widget text, {
  Locale locale = _en,
}) async {
  await tester.pumpWidget(
    localeLayoutApp(
      locale: locale,
      home: Scaffold(body: Center(child: text)),
    ),
  );
  return tester.renderObject<RenderParagraph>(find.byType(RichText).last);
}

double _directWidth(String text, String family, {double fontSize = 14}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontFamily: family, fontSize: fontSize),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

void _expectDefect(WidgetTester tester, {LayoutProfile? profile}) {
  expect(
    () => expectLocaleLayoutIntact(
      tester,
      locale: _en,
      profile: profile ?? LayoutProfile.regular,
    ),
    throwsA(isA<TestFailure>()),
  );
}

void main() {
  group('glyph widths', () {
    // The theme's body style adds letter spacing; the direct measurements
    // below have none.
    const style = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
    );

    testWidgets('Latin measures in Montserrat', (tester) async {
      final paragraph = await _pumpText(
        tester,
        const Text('Recommended', style: style),
      );
      expect(
        paragraph.size.width,
        moreOrLessEquals(_directWidth('Recommended', 'Montserrat')),
      );
      // FlutterTest would draw 11 one-em squares.
      expect(paragraph.size.width, lessThan(11 * 14 * 0.8));
    });

    testWidgets('Cyrillic falls back to Roboto', (tester) async {
      const text = 'Подписаться на пользователя';
      final paragraph = await _pumpText(
        tester,
        const Text(text, style: style),
        locale: const Locale('ru'),
      );
      // Not Montserrat's missing-glyph boxes, not one-em squares.
      expect(
        paragraph.size.width,
        moreOrLessEquals(_directWidth(text, 'Roboto'), epsilon: 0.5),
      );
      expect(paragraph.size.width, lessThan(text.length * 14 * 0.7));
    });

    testWidgets('CJK is 1em a character, half-width kana 0.5em', (
      tester,
    ) async {
      final cjk = await _pumpText(
        tester,
        const Text('关注用户', style: style),
        locale: const Locale('zh'),
      );
      expect(cjk.size.width, moreOrLessEquals(56, epsilon: 0.01));

      final kana = await _pumpText(
        tester,
        const Text('ｱｲｳ', style: style),
        locale: const Locale('ja'),
      );
      expect(kana.size.width, moreOrLessEquals(21, epsilon: 0.01));
    });
  });

  group('the detector', () {
    testWidgets('accepts whole UI text', (tester) async {
      await _pumpText(tester, const SizedBox(width: 200, child: Text(_hint)));
      expectLocaleLayoutIntact(
        tester,
        locale: _en,
        profile: LayoutProfile.regular,
      );
    });

    testWidgets('catches UI text ellipsized at maxLines', (tester) async {
      await _pumpText(
        tester,
        const SizedBox(
          width: 60,
          child: Text(_short, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      );
      _expectDefect(tester);
    });

    testWidgets('catches two lines pressed into one line of height', (
      tester,
    ) async {
      await _pumpText(
        tester,
        const SizedBox(width: 200, height: 18, child: Text(_hint)),
      );
      _expectDefect(tester);
    });

    testWidgets('catches a Row overflow', (tester) async {
      await _pumpText(
        tester,
        const SizedBox(
          width: 60,
          child: Row(children: [Text(_short, softWrap: false)]),
        ),
      );
      _expectDefect(tester);
    });

    testWidgets('catches a FittedBox shrinking UI text below 0.8', (
      tester,
    ) async {
      final width = _directWidth(_short, 'Montserrat');
      await _pumpText(
        tester,
        SizedBox(
          width: width * 0.6,
          child: const FittedBox(child: Text(_short)),
        ),
      );
      _expectDefect(tester);
    });

    testWidgets('lets user content ellipsize', (tester) async {
      await _pumpText(
        tester,
        const SizedBox(
          width: 60,
          child: Text(
            'A very long artwork title',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
      expectLocaleLayoutIntact(
        tester,
        locale: _en,
        profile: LayoutProfile.regular,
      );
    });

    testWidgets('lets a FitLabel ellipsize in the compact profile only', (
      tester,
    ) async {
      await _pumpText(
        tester,
        const SizedBox(
          width: 40,
          child: FitLabel(
            _short,
            fit: LabelFit(scale: LabelFit.minScale, truncates: true),
            style: TextStyle(fontSize: 14),
          ),
        ),
      );
      expectLocaleLayoutIntact(
        tester,
        locale: _en,
        profile: LayoutProfile.compact,
      );
      _expectDefect(tester, profile: LayoutProfile.regular);
    });
  });

  group('message matching', () {
    test('placeholder messages match with any argument', () {
      final zh = LocaleMessages.of(const Locale('zh'));
      expect(zh.keyOf('共 12 页'), 'illustPagesTotal');
      expect(zh.keyOf('第 3 话'), 'seriesEpisode');
    });

    test('placeholder-and-punctuation messages claim no user text', () {
      final en = LocaleMessages.of(_en);
      expect(en.keyOf('Chapter one: the beginning'), isNull);
      expect(en.keyOf(_short), 'motionPageTransition');
    });
  });
}
