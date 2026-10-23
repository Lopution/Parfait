import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/widgets/feed/feed_text_warmup.dart';

/// Expects each of [texts] to describe a paragraph laid out below [root]
/// (anywhere without it): the same runs in the same styles, colour aside
/// as it is no part of a layout, in the same locale with the same strut.
void expectLaidOutAsWarmed(
  WidgetTester tester,
  Iterable<WarmText> texts, {
  Finder? root,
}) {
  final laidOut = <WarmText>[];
  void visit(RenderObject object) {
    switch (object) {
      case RenderParagraph(:final TextSpan text):
        laidOut.add((
          span: text,
          locale: object.locale,
          strutStyle: object.strutStyle,
        ));
      case RenderEditable(:final TextSpan text):
        laidOut.add((
          span: text,
          locale: object.locale,
          strutStyle: object.strutStyle,
        ));
      default:
    }
    if (root != null) object.visitChildren(visit);
  }

  if (root == null) {
    tester.allRenderObjects.forEach(visit);
  } else {
    visit(tester.renderObject(root));
  }
  for (final text in texts) {
    final plain = text.span.toPlainText();
    final candidates = [
      for (final p in laidOut)
        if (p.span.toPlainText() == plain) p,
    ];
    if (candidates.isEmpty) fail('no paragraph reads "$plain"');
    // The same text can be laid out more than once (a name in a heading).
    final paragraph = candidates.firstWhere(
      (p) =>
          listEquals(_runs(p.span), _runs(text.span)) &&
          p.locale == text.locale &&
          p.strutStyle == text.strutStyle,
      orElse: () => candidates.first,
    );
    expect(_runs(paragraph.span), _runs(text.span), reason: plain);
    expect(paragraph.locale, text.locale, reason: plain);
    expect(paragraph.strutStyle, text.strutStyle, reason: plain);
  }
}

/// The text of [span] run by run, each in its effective style.
List<(String, TextStyle?)> _runs(TextSpan span) {
  const anyColour = Color(0xFF000000);
  final runs = <(String, TextStyle?)>[];
  void visit(InlineSpan span, TextStyle? inherited) {
    final style = inherited?.merge(span.style) ?? span.style;
    if (span is! TextSpan) return;
    if (span.text case final text? when text.isNotEmpty) {
      runs.add((text, style?.copyWith(color: anyColour)));
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child, style);
    }
  }

  visit(span, null);
  return runs;
}
