import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/core/platform/app_root_pipeline_owner.dart';

/// The app's binding swaps in [AppRootPipelineOwner]; this one does the same
/// on top of the test binding.
class _AppRootBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  PipelineOwner createRootPipelineOwner() => AppRootPipelineOwner();
}

/// Frame timestamps of the semantics updates the view sent to the platform.
List<Duration> _recordPushes(WidgetTester tester) {
  final pushes = <Duration>[];
  tester.binding.renderViews.first.owner!.semanticsOwner!.addListener(
    () => pushes.add(tester.binding.currentSystemFrameTimeStamp),
  );
  return pushes;
}

SemanticsData? _scrollData(WidgetTester tester) {
  SemanticsData? found;
  bool visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.scrollPosition != null) {
      found = data;
    } else {
      node.visitChildren(visit);
    }
    return found == null;
  }

  visit(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return found;
}

void main() {
  _AppRootBinding();

  testWidgets('a scrolling feed pushes semantics at most once per interval '
      'and the last state arrives once it stops', (tester) async {
    final handle = tester.ensureSemantics();
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              scrollCacheExtent: kFeedCacheExtent,
              slivers: [
                IllustFeedGrid(
                  itemCount: 300,
                  itemBuilder: (context, index) => SizedBox(
                    height: 160.0 + index % 3 * 60,
                    child: TextButton(
                      onPressed: () {},
                      child: Text('work $index'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final pushes = _recordPushes(tester);

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -400),
      2500,
    );
    var frames = 0;
    for (; frames < 60; frames++) {
      await tester.pump(const Duration(milliseconds: 8));
    }
    // Half a second of frames, all while the fling runs.
    expect(controller.position.isScrollingNotifier.value, isTrue);
    expect(pushes.length, greaterThanOrEqualTo(5));
    expect(pushes.length, lessThan(frames ~/ 6));
    for (var i = 1; i < pushes.length; i++) {
      expect(
        pushes[i] - pushes[i - 1],
        greaterThanOrEqualTo(kSemanticsPushInterval),
      );
    }

    await tester.pumpAndSettle();
    await tester.binding.delayed(kSemanticsPushInterval * 2);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(controller.offset, greaterThan(1000));
    expect(_scrollData(tester)!.scrollPosition, controller.offset);
    final firstVisible = find
        .textContaining('work ')
        .hitTestable(at: Alignment.topCenter)
        .first;
    expect(
      find.semantics.byLabel(tester.widget<Text>(firstVisible).data!),
      findsOne,
    );
    handle.dispose();
  });

  testWidgets('a change after a quiet interval is pushed in its frame; one '
      'inside the interval waits for the timer-requested frame', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final label = ValueNotifier('a');
    addTearDown(label.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: label,
          builder: (context, value, _) => Text(value),
        ),
      ),
    );
    final pushes = _recordPushes(tester);
    await tester.binding.delayed(kSemanticsPushInterval);

    label.value = 'b';
    await tester.pump();
    expect(pushes, hasLength(1));
    expect(find.semantics.byLabel('b'), findsOne);

    label.value = 'c';
    await tester.pump(const Duration(milliseconds: 16));
    expect(pushes, hasLength(1));
    expect(find.semantics.byLabel('c'), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.binding.delayed(kSemanticsPushInterval);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(pushes, hasLength(2));
    expect(find.semantics.byLabel('c'), findsOne);
    handle.dispose();
  });

  testWidgets('a hold keeps changes back until an interval after its '
      'release, and gives way at its limit', (tester) async {
    final handle = tester.ensureSemantics();
    final label = ValueNotifier('a');
    addTearDown(label.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: label,
          builder: (context, value, _) => Text(value),
        ),
      ),
    );
    final pushes = _recordPushes(tester);
    await tester.binding.delayed(kSemanticsPushInterval);

    final release = AppRootPipelineOwner.holdSemantics();
    label.value = 'b';
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(pushes, isEmpty);
    release();
    release();
    await tester.pump(const Duration(milliseconds: 16));
    expect(pushes, isEmpty);
    await tester.binding.delayed(kSemanticsPushInterval);
    await tester.pump();
    expect(pushes, hasLength(1));
    expect(find.semantics.byLabel('b'), findsOne);

    final stuck = AppRootPipelineOwner.holdSemantics();
    label.value = 'c';
    await tester.pump();
    expect(find.semantics.byLabel('c'), findsNothing);
    await tester.binding.delayed(kSemanticsHoldLimit);
    await tester.pump();
    expect(find.semantics.byLabel('c'), findsOne);
    stuck();
    await tester.binding.delayed(kSemanticsPushInterval);
    handle.dispose();
  });
}
