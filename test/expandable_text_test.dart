import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/expandable_text.dart';
import 'helpers/localized_app.dart';

Widget _host(Widget child) => localizedApp(
  body: SingleChildScrollView(child: SizedBox(width: 300, child: child)),
);

final _long = List.filled(40, 'a long caption line').join(' ');

// Collapsed, the text is painted twice; the first copy is the unmasked one.
Finder get _lines => find
    .descendant(
      of: find.byType(ExpandableText),
      matching: find.byType(RichText),
    )
    .first;

void main() {
  testWidgets('long text collapses to maxLines and expands on demand', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(ExpandableText(TextSpan(text: _long), maxLines: 3)),
    );

    expect(tester.widget<RichText>(_lines).maxLines, 3);
    // "Show more" ends the last line instead of adding one under it.
    final block = tester.getRect(find.byType(ExpandableText));
    expect(block.height, tester.getSize(_lines).height);
    expect(tester.getRect(find.text('展开')).right, block.right);
    expect(
      tester.getRect(find.text('展开')).bottom,
      lessThanOrEqualTo(block.bottom),
    );
    expect(
      tester.getSemantics(
        find.descendant(
          of: find.byType(ExpandableText),
          matching: find.byType(InkWell),
        ),
      ),
      isSemantics(
        hasExpandedState: true,
        isExpanded: false,
        hasTapAction: true,
        onTapHint: '展开',
      ),
    );

    // A tap anywhere on the text expands it.
    await tester.tapAt(block.topLeft + const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(tester.widget<RichText>(_lines).maxLines, isNull);
    expect(
      tester.getSize(find.byType(ExpandableText)).height,
      greaterThan(block.height),
    );
    expect(
      tester.getSemantics(find.byType(TextButton)),
      isSemantics(isButton: true, hasExpandedState: true, isExpanded: true),
    );

    await tester.ensureVisible(find.text('收起'));
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(tester.widget<RichText>(_lines).maxLines, 3);
    expect(tester.getSize(find.byType(ExpandableText)).height, block.height);
    semantics.dispose();
  });

  testWidgets('a link stays tappable while collapsed', (tester) async {
    var taps = 0;
    final recognizer = TapGestureRecognizer()..onTap = () => taps++;
    addTearDown(recognizer.dispose);
    await tester.pumpWidget(
      _host(
        ExpandableText(
          TextSpan(
            children: [
              TextSpan(text: 'link', recognizer: recognizer),
              TextSpan(text: ' $_long'),
            ],
          ),
          maxLines: 2,
        ),
      ),
    );
    expect(find.text('展开'), findsOneWidget);

    await tester.tapOnText(find.textRange.ofSubstring('link').first);
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(find.text('展开'), findsOneWidget);
  });
}
