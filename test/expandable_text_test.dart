import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/expandable_text.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

Widget _host(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  supportedLocales: const [Locale('zh')],
  localizationsDelegates: appLocalizationsDelegates,
  home: Scaffold(
    body: SingleChildScrollView(child: SizedBox(width: 300, child: child)),
  ),
);

final _long = List.filled(40, 'a long caption line').join(' ');

RichText _text(WidgetTester tester) => tester.widget<RichText>(
  find
      .descendant(
        of: find.byType(ExpandableText),
        matching: find.byType(RichText),
      )
      .first,
);

void main() {
  testWidgets('long text collapses to maxLines and expands on demand', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(ExpandableText(TextSpan(text: _long), maxLines: 3)),
    );

    expect(_text(tester).maxLines, 3);
    expect(_text(tester).overflow, TextOverflow.ellipsis);
    expect(find.text('展开'), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(TextButton)),
      isSemantics(isButton: true, hasExpandedState: true, isExpanded: false),
    );
    final collapsedHeight = tester.getSize(find.byType(ExpandableText)).height;

    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(_text(tester).maxLines, isNull);
    expect(
      tester.getSize(find.byType(ExpandableText)).height,
      greaterThan(collapsedHeight),
    );
    expect(
      tester.getSemantics(find.byType(TextButton)),
      isSemantics(isButton: true, hasExpandedState: true, isExpanded: true),
    );

    await tester.ensureVisible(find.text('收起'));
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(_text(tester).maxLines, 3);
    expect(tester.getSize(find.byType(ExpandableText)).height, collapsedHeight);
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

    await tester.tapOnText(find.textRange.ofSubstring('link'));
    expect(taps, 1);
  });
}
