import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/scroll_behavior.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/core/platform/app_root_pipeline_owner.dart';

import 'helpers/localized_app.dart';

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

Widget _rows({ScrollController? controller}) => ListView.builder(
  controller: controller,
  physics: const AlwaysScrollableScrollPhysics(),
  itemCount: 200,
  itemBuilder: (_, index) => SizedBox(height: 80, child: Text('row $index')),
);

Future<void> _flingFor(WidgetTester tester, int frames) async {
  await tester.fling(find.text('row 2'), const Offset(0, -400), 2500);
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 8));
  }
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

  testWidgets('a list unmounted mid-fling releases its hold', (tester) async {
    final handle = tester.ensureSemantics();
    final controller = ScrollController();
    final swapped = ValueNotifier(false);
    final label = ValueNotifier('a');
    addTearDown(controller.dispose);
    addTearDown(swapped.dispose);
    addTearDown(label.dispose);
    await tester.pumpWidget(
      localizedApp(
        scrollBehavior: const FuncScrollBehavior(),
        body: ListenableBuilder(
          listenable: Listenable.merge([swapped, label]),
          builder: (context, _) => Column(
            children: [
              Text(label.value),
              Expanded(
                child: swapped.value
                    ? const SizedBox()
                    : _rows(controller: controller),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.binding.delayed(kSemanticsPushInterval);
    final start = tester.binding.clock.now();
    final pushes = _recordPushes(tester);
    await _flingFor(tester, 20);
    expect(controller.position.isScrollingNotifier.value, isTrue);
    expect(pushes, isEmpty);

    swapped.value = true;
    await tester.pump();
    label.value = 'b';
    await tester.pump(const Duration(milliseconds: 16));
    await tester.binding.delayed(kSemanticsPushInterval);
    await tester.pump();
    // Inside the hold limit: only a released hold lets 'b' out.
    expect(
      tester.binding.clock.now().difference(start),
      lessThan(kSemanticsHoldLimit),
    );
    expect(find.semantics.byLabel('b'), findsOne);
    await tester.binding.delayed(kSemanticsPushInterval);
    handle.dispose();
  });
}
