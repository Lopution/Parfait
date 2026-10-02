import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/app/widgets/skeleton/func_skeleton.dart';
import 'package:parfait/app/widgets/skeleton/illust_grid_skeleton.dart';

Widget _host(Widget child, {bool reduce = false}) {
  return MotionScope(
    reduce: reduce,
    child: MaterialApp(
      home: Scaffold(body: SizedBox(height: 400, child: child)),
    ),
  );
}

void main() {
  testWidgets('FuncSkeleton exposes exactly one semantics label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const FuncSkeleton(
          label: 'Loading content',
          child: Column(
            children: [
              SkeletonBone(width: 100, height: 20),
              SkeletonBone.text(width: 60),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // One labelled node, and ExcludeSemantics keeps the bones from
    // producing duplicate announcements.
    final finder = find.bySemanticsLabel('Loading content');
    expect(finder, findsOneWidget);
    expect(tester.getSemantics(finder).childrenCount, 0);
  });

  testWidgets('reduced motion renders static bones without a shader', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const FuncSkeleton(
          label: 'Loading content',
          child: SkeletonBone(width: 100, height: 20),
        ),
        reduce: true,
      ),
    );
    await tester.pump();

    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('normal motion keeps the shimmer running', (tester) async {
    await tester.pumpWidget(
      _host(
        const FuncSkeleton(
          label: 'Loading content',
          child: SkeletonBone(width: 100, height: 20),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(ShaderMask), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('a nested skeleton defers to the outer shimmer and label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const FuncSkeleton(
          label: 'Loading page',
          child: Column(
            children: [
              SkeletonBone(width: 100, height: 20),
              Expanded(child: IllustGridSkeleton(label: 'Loading grid')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // One sweep for the whole tree, one announcement.
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(find.bySemanticsLabel('Loading page'), findsOneWidget);
    expect(find.bySemanticsLabel('Loading grid'), findsNothing);
  });

  testWidgets('IllustGridSkeleton column count follows illustColumnsFor', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Set<double> cardXs() {
      return tester
          .widgetList<SkeletonBone>(find.byType(SkeletonBone))
          .where((bone) => bone.borderRadius == FuncShape.card)
          .map(
            (bone) =>
                tester.getTopLeft(find.byWidgetPredicate((w) => w == bone)).dx,
          )
          .toSet();
    }

    // Phone width: two columns.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    await tester.pumpWidget(
      _host(const IllustGridSkeleton(label: 'Loading content')),
    );
    await tester.pump();
    expect(cardXs().length, 2);

    // Wide width: same count as the live grid would compute.
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pump();
    expect(
      cardXs().length,
      illustColumnsFor(1200 - IllustFeedGrid.defaultPadding.horizontal),
    );
  });

  test('grid skeleton defaults mirror the live grid', () {
    const skeleton = IllustGridSkeleton(label: 'Loading content');
    expect(skeleton.padding, IllustFeedGrid.defaultPadding);
    expect(skeleton.mainAxisSpacing, IllustFeedGrid.defaultMainAxisSpacing);
    expect(skeleton.crossAxisSpacing, IllustFeedGrid.defaultCrossAxisSpacing);
  });

  testWidgets('grid bones use the placeholder colour and card radius', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);

    await tester.pumpWidget(
      _host(const IllustGridSkeleton(label: 'Loading content')),
    );
    await tester.pump();

    final context = tester.element(find.byType(IllustGridSkeleton));
    final expected = Theme.of(context).colorScheme.surfaceContainer;
    final bone = tester.widget<Container>(
      find.descendant(
        of: find.byType(SkeletonBone).first,
        matching: find.byType(Container),
      ),
    );
    expect((bone.decoration! as BoxDecoration).color, expected);
    expect((bone.decoration! as BoxDecoration).borderRadius, FuncShape.card);
  });
}
