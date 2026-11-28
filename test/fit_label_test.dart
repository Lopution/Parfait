import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/fit_label.dart';

const _style = TextStyle(fontSize: 10);

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // FlutterTest glyphs are 1em: a ten-letter label is 100px at 10px.
  test('a group scales to its widest label, down to 0.8, then ellipsizes', () {
    // Labels that fit, or an unbounded slot, keep their size.
    expect(_fit(['abcde', 'abcdefghij'], 100), LabelFit.none);
    expect(_fit(['abcdefghij'], double.infinity), LabelFit.none);

    final group = _fit(['abcde', 'abcdefghij'], 90);
    // One pixel of slack against rounding at the scaled size.
    expect(group.scale, moreOrLessEquals(89 / 100));
    expect(group.truncates, isFalse);

    final tight = _fit(['abcdefghij'], 50);
    expect(tight.scale, LabelFit.minScale);
    expect(tight.truncates, isTrue);
  });
}
