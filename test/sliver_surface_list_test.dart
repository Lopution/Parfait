import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/app/widgets/sliver_surface_list.dart';

const _radius = BorderRadius.all(Radius.circular(12));
const _gap = 8.0;
const _rowHeight = 50.0;
const _surfaceColor = Color(0xFF00FF00);
const _rowColor = Color(0xFFFF0000);

/// A list of [groups] in the default 800×600 test view; row [index] is
/// [heights]`[index]` tall, or [_rowHeight].
Future<RenderSliverSurfaceList> _pumpList(
  WidgetTester tester,
  List<Object> groups, {
  Map<int, double> heights = const {},
  ScrollController? controller,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: CustomScrollView(
        controller: controller,
        slivers: [
          SliverSurfaceList.builder(
            groups: groups,
            color: _surfaceColor,
            borderRadius: _radius,
            leadingGap: _gap,
            itemBuilder: (context, index) => SizedBox(
              height: heights[index] ?? _rowHeight,
              child: const ColoredBox(color: _rowColor),
            ),
          ),
        ],
      ),
    ),
  );
  return tester.renderObject(find.byType(SliverSurfaceList));
}

RRect _rrect(double top, double bottom) =>
    _radius.toRRect(Rect.fromLTRB(0, top, 800, bottom));

void main() {
  testWidgets('consecutive rows of a group share one surface below its gap', (
    tester,
  ) async {
    final list = await _pumpList(tester, ['a', 'a', 'b', 'c', 'c', 'c']);

    expect(list.surfaces, [
      _rrect(_gap, 100),
      _rrect(100 + _gap, 150),
      _rrect(150 + _gap, 300),
    ]);
  });

  testWidgets('paints each surface, then its rows clipped to it', (
    tester,
  ) async {
    final list = await _pumpList(tester, ['a', 'a', 'b']);

    expect(
      list,
      paints
        ..rrect(rrect: _rrect(_gap, 100), color: _surfaceColor)
        ..clipRRect(rrect: _rrect(_gap, 100))
        ..rect(color: _rowColor)
        ..rect(color: _rowColor)
        ..rrect(rrect: _rrect(100 + _gap, 150), color: _surfaceColor)
        ..clipRRect(rrect: _rrect(100 + _gap, 150))
        ..rect(color: _rowColor),
    );
    // Rows are repaint boundaries, so each surface clips with a layer;
    // a surface that goes away takes its layer along.
    expect(tester.layers.whereType<ClipRRectLayer>(), hasLength(2));
    await _pumpList(tester, ['a', 'a', 'a']);
    expect(tester.layers.whereType<ClipRRectLayer>(), hasLength(1));
  });

  testWidgets('a group cut off by the cache extent runs its corners off '
      'screen', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final list = await _pumpList(
      tester,
      List.filled(100, 'a'),
      controller: controller,
    );
    controller.jumpTo(2000);
    await tester.pump();

    final surface = list.surfaces.single;
    expect(surface.top, lessThanOrEqualTo(-_radius.topLeft.y));
    expect(surface.bottom, greaterThanOrEqualTo(600 + _radius.bottomLeft.y));
  });

  testWidgets('a first row folded into its gap paints no surface', (
    tester,
  ) async {
    final list = await _pumpList(tester, ['a', 'b'], heights: {0: _gap / 2});

    expect(
      list,
      paints..rrect(rrect: _rrect(_gap / 2 + _gap, _gap / 2 + _rowHeight)),
    );
    expect(list, paintsExactlyCountTimes(#drawRRect, 1));
  });
}
