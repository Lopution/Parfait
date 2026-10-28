import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/pull_to_refresh.dart';
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

Widget _rows({
  ScrollController? controller,
  ScrollPhysics physics = const AlwaysScrollableScrollPhysics(),
}) => ListView.builder(
  controller: controller,
  physics: physics,
  itemCount: 200,
  itemBuilder: (_, index) => SizedBox(height: 80, child: Text('row $index')),
);

bool _anyScrolling(WidgetTester tester) => tester
    .stateList<ScrollableState>(find.byType(Scrollable))
    .any((state) => state.position.isScrollingNotifier.value);

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

  final layouts = <String, Widget Function()>{
    'list': _rows,
    'feed': () => PullToRefresh(onRefresh: () async {}, child: _rows()),
    'nested list': () => NestedScrollView(
      headerSliverBuilder: (_, _) => const [
        SliverToBoxAdapter(child: SizedBox(height: 180)),
      ],
      body: _rows(),
    ),
  };
  for (final MapEntry(key: name, value: layout) in layouts.entries) {
    testWidgets('a $name under the app scroll behavior pushes no semantics '
        'while it scrolls, and its final state once it stops', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        localizedApp(
          scrollBehavior: const FuncScrollBehavior(),
          body: layout(),
        ),
      );
      await tester.binding.delayed(kSemanticsPushInterval);
      final pushes = _recordPushes(tester);

      await _flingFor(tester, 60);
      expect(_anyScrolling(tester), isTrue);
      expect(pushes, isEmpty);

      await tester.pumpAndSettle();
      await tester.binding.delayed(kSemanticsPushInterval);
      await tester.pump();
      expect(pushes, isNotEmpty);
      final firstVisible = find
          .textContaining('row ')
          .hitTestable(at: Alignment.topCenter)
          .first;
      expect(tester.widget<Text>(firstVisible).data, isNot('row 0'));
      expect(
        find.semantics.byLabel(tester.widget<Text>(firstVisible).data!),
        findsOne,
      );
      handle.dispose();
    });
  }

  for (final unmount in [true, false]) {
    testWidgets(
      unmount
          ? 'a list unmounted mid-fling releases its hold'
          : 'a list given a new position mid-fling holds until it stops',
      (tester) async {
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
                    child: switch ((swapped.value, unmount)) {
                      (true, true) => const SizedBox(),
                      // A new physics type makes the scrollable replace
                      // its position; the new one absorbs the fling.
                      (true, false) => _rows(
                        controller: controller,
                        physics: const ClampingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                      ),
                      _ => _rows(controller: controller),
                    },
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
        final old = controller.position;
        expect(old.isScrollingNotifier.value, isTrue);
        expect(pushes, isEmpty);

        swapped.value = true;
        await tester.pump();
        label.value = 'b';
        await tester.pump(const Duration(milliseconds: 16));
        if (!unmount) {
          expect(controller.position, isNot(same(old)));
          expect(_anyScrolling(tester), isTrue);
          expect(find.semantics.byLabel('b'), findsNothing);
          await tester.pumpAndSettle();
        }
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
      },
    );
  }

  for (final repeats in [false, true]) {
    testWidgets(
      'a released hold waits for '
      '${repeats ? 'its limit while an animation repeats' : 'a running animation to end'}',
      (tester) async {
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
        await tester.binding.delayed(kSemanticsPushInterval);
        final animation = AnimationController(
          vsync: tester,
          duration: const Duration(milliseconds: 500),
        );
        addTearDown(animation.dispose);

        final release = AppRootPipelineOwner.holdSemantics();
        label.value = 'b';
        unawaited(repeats ? animation.repeat() : animation.forward());
        await tester.pump();
        release();
        await tester.pump(kSemanticsPushInterval);
        await tester.pump(const Duration(milliseconds: 16));
        expect(animation.isAnimating, isTrue);
        expect(find.semantics.byLabel('b'), findsNothing);

        if (repeats) {
          await tester.pump(kSemanticsHoldLimit - kSemanticsPushInterval);
          await tester.pump();
          expect(animation.isAnimating, isTrue);
          animation.stop();
        } else {
          await tester.pump(const Duration(milliseconds: 400));
          expect(animation.isCompleted, isTrue);
          expect(find.semantics.byLabel('b'), findsNothing);
          await tester.pump();
          await tester.pump();
        }
        expect(find.semantics.byLabel('b'), findsOne);
        await tester.binding.delayed(kSemanticsPushInterval);
        handle.dispose();
      },
    );
  }
}
