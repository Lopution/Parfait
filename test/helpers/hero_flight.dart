import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/app/motion/hero_rect_clip.dart';

/// The clip a Hero flight's shuttle is given this frame, on screen.
Rect heroClipRect(WidgetTester tester) {
  final clip = tester.widget<Widget>(find.byType(HeroRectClip));
  return (clip as dynamic).globalRect as Rect;
}

/// The clip the flight's last paint used, on screen.
Rect? heroPaintClipRect(WidgetTester tester) {
  final render = tester.renderObject(find.byType(HeroRectClip));
  return (render as dynamic).debugLastPaintClipRect as Rect?;
}

/// The card page's bars a flight last painted over its image, and their
/// content's opacity; none outside a card flight.
List<({Rect rect, double opacity, int shadows})> liftedBars(
  WidgetTester tester,
) {
  final paint = find.byWidgetPredicate(
    (widget) => '${widget.runtimeType}' == '_LiftedBarsPaint',
  );
  if (paint.evaluate().isEmpty) return const [];
  return (tester.renderObject(paint) as dynamic).debugLastPaintedBars
      as List<({Rect rect, double opacity, int shadows})>;
}
