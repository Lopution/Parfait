import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/fit_label.dart';

const _style = TextStyle(fontSize: 10);

/// Android 14 style: large sizes grow less than small ones.
final class _NonLinearScaler extends TextScaler {
  const _NonLinearScaler();

  @override
  double scale(double fontSize) => fontSize * 1.5 + 2;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => 1.5;
}

LabelFit _fit(
  List<String> labels,
  double slotWidth, {
  TextScaler textScaler = TextScaler.noScaling,
}) => LabelFit.group(
  labels: labels,
  style: _style,
  textScaler: textScaler,
  textDirection: TextDirection.ltr,
  slotWidth: slotWidth,
);

Future<RenderParagraph> _pump(
  WidgetTester tester,
  String text,
  LabelFit fit, {
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: textScaler),
        child: Center(
          child: FitLabel(text, fit: fit, style: _style),
        ),
      ),
    ),
  );
  return tester.renderObject<RenderParagraph>(find.byType(RichText).last);
}

void main() {
  // FlutterTest glyphs are 1em: a ten-letter label is 100px at 10px.
  test('labels that fit keep their size', () {
    expect(_fit(['abcde', 'abcdefghij'], 100), LabelFit.none);
  });

  test('the widest label sets one scale for the group', () {
    final fit = _fit(['abcde', 'abcdefghij'], 90);
    // One pixel of slack against rounding at the scaled size.
    expect(fit.scale, moreOrLessEquals(89 / 100));
    expect(fit.truncates, isFalse);
  });

  test('the scale stops at 0.8, then the group ellipsizes', () {
    final fit = _fit(['abcdefghij'], 50);
    expect(fit.scale, LabelFit.minScale);
    expect(fit.truncates, isTrue);
  });

  test('an unbounded slot never scales', () {
    expect(_fit(['abcdefghij'], double.infinity), LabelFit.none);
  });

  testWidgets('the painted width is the measured width times the scale', (
    tester,
  ) async {
    final fit = _fit(['abcdefghij'], 90);
    final paragraph = await _pump(tester, 'abcdefghij', fit);
    final measured = LabelFit.measureLabel(
      'abcdefghij',
      _style,
      fit.scaler(TextScaler.noScaling),
      TextDirection.ltr,
    );
    expect(paragraph.size.width, measured);
    // Within the slot, a hair under the linear estimate.
    expect(paragraph.size.width, lessThanOrEqualTo(90));
    expect(find.byType(Tooltip), findsNothing);
  });

  testWidgets('a non-linear text scaler measures and paints alike', (
    tester,
  ) async {
    const scaler = _NonLinearScaler();
    final fit = _fit(['abcdefghij'], 150, textScaler: scaler);
    // 10px scales to 17px: 170px natural, about 149 / 170 of it painted.
    expect(fit.scale, moreOrLessEquals(149 / 170));
    final paragraph = await _pump(
      tester,
      'abcdefghij',
      fit,
      textScaler: scaler,
    );
    expect(paragraph.size.width, lessThanOrEqualTo(150));
    expect(paragraph.size.width, greaterThan(148));
  });

  testWidgets('an ellipsized label carries its full text in a tooltip', (
    tester,
  ) async {
    final fit = _fit(['abcdefghij'], 50);
    await _pump(tester, 'abcdefghij', fit);
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, 'abcdefghij');
  });
}
