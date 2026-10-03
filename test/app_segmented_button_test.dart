import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/app_segmented_button.dart';
import 'package:parfait/app/widgets/app_type_switch.dart';
import 'package:parfait/app/widgets/fit_label.dart';

Future<void> _pump(WidgetTester tester, Widget child, {double width = 400}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

Widget _picker(List<String> labels, {int selected = 0}) =>
    AppSegmentedButton<int>(
      segments: [
        for (var i = 0; i < labels.length; i++)
          AppSegment(value: i, label: labels[i]),
      ],
      selected: selected,
      onSelected: (_) {},
    );

Set<LabelFit> _fits(WidgetTester tester) => tester
    .widgetList<FitLabel>(find.byType(FitLabel))
    .map((l) => l.fit)
    .toSet();

void main() {
  testWidgets('no check glyph: the selected segment keeps its width', (
    tester,
  ) async {
    await _pump(tester, _picker(const ['ab', 'cd']));
    expect(find.byIcon(Icons.check), findsNothing);
    final first = tester.getSize(find.text('ab')).width;
    await _pump(tester, _picker(const ['ab', 'cd'], selected: 1));
    expect(tester.getSize(find.text('ab')).width, first);
  });

  testWidgets('segments share one width and one label scale', (tester) async {
    // FlutterTest glyphs are 1em: 'abcdefghijkl' at 14px is 168px, wider
    // than a third of a 500px row less the segment padding (142px).
    await _pump(
      tester,
      _picker(const ['a', 'abcdefghijkl', 'abc']),
      width: 500,
    );
    final fits = _fits(tester);
    expect(fits, hasLength(1));
    expect(fits.single.scale, inExclusiveRange(LabelFit.minScale, 1));
    final widths = {
      for (final label in ['a', 'abcdefghijkl', 'abc'])
        tester
            .getSize(
              find.ancestor(
                of: find.text(label),
                matching: find.byType(TextButton),
              ),
            )
            .width,
    };
    expect(widths, hasLength(1));
    // The widest label fits its scaled slot whole.
    final widest = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.text('abcdefghijkl'),
        matching: find.byType(RichText),
      ),
    );
    expect(widest.didExceedMaxLines, isFalse);
  });

  testWidgets('labels that fit keep their size', (tester) async {
    await _pump(tester, _picker(const ['ab', 'cd']));
    expect(_fits(tester), {LabelFit.none});
  });

  testWidgets('in the scrolling type switch labels never shrink', (
    tester,
  ) async {
    await _pump(
      tester,
      AppTypeSwitch<int>(
        options: const [
          (value: 0, label: 'abcdefghijkl'),
          (value: 1, label: 'mnopqrstuvwx'),
          (value: 2, label: 'yz'),
        ],
        selected: 0,
        onSelected: (_) {},
      ),
      width: 300,
    );
    expect(_fits(tester), {LabelFit.none});
    expect(tester.takeException(), isNull);
  });
}
