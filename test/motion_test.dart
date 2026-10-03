import 'dart:async';

import 'package:flutter/gestures.dart' show kPressTimeout;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/haptics/app_haptics.dart';
import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/motion/app_overlays.dart';
import 'package:parfait/app/motion/drag_to_dismiss.dart';
import 'package:parfait/app/motion/feed_entrance.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/motion/press_scale.dart';
import 'package:parfait/app/motion/removal.dart';
import 'package:parfait/app/motion/spring_size.dart';
import 'package:parfait/app/motion/state_fade.dart';
import 'package:parfait/app/motion/state_icon_switcher.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/app_snack_bar.dart';
import 'package:parfait/core/settings/app_settings.dart';

import 'helpers/recording_haptics.dart';

Widget _wrap(
  Widget child, {
  bool reduce = false,
  bool platformDisable = false,
  AnimationSpeed speed = AnimationSpeed.normal,
}) {
  final app = MaterialApp(
    theme: replicaTheme(Brightness.light),
    home: MotionScope(
      reduce: reduce,
      speed: speed,
      child: Scaffold(body: child),
    ),
  );
  if (!platformDisable) return app;
  return MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: app,
  );
}

/// The rendered press scale: PressScale drives a [ScaleTransition] from its
/// own spring controller. 1.0 when the wrapper renders no transition.
double _pressScale(WidgetTester tester) {
  final transition = find.descendant(
    of: find.byType(PressScale),
    matching: find.byType(ScaleTransition),
  );
  if (transition.evaluate().isEmpty) return 1;
  return tester.widget<ScaleTransition>(transition).scale.value;
}

/// Counts State creations — a re-inflated card mounts a second time.
class _MountCounter extends StatefulWidget {
  const _MountCounter({required this.onMount});

  final VoidCallback onMount;

  @override
  State<_MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<_MountCounter> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const Text('card');
}

void main() {
  group('MotionTokens gate', () {
    Future<Duration> resolve(
      WidgetTester tester, {
      bool reduce = false,
      bool platformDisable = false,
      AnimationSpeed speed = AnimationSpeed.normal,
    }) async {
      Duration? resolved;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) {
              resolved = MotionTokens.resolve(context, MotionTokens.medium);
              return const SizedBox.shrink();
            },
          ),
          reduce: reduce,
          platformDisable: platformDisable,
          speed: speed,
        ),
      );
      return resolved!;
    }

    testWidgets('scales by the animation speed', (tester) async {
      expect(
        await resolve(tester, speed: AnimationSpeed.slow),
        MotionTokens.medium * (450 / 350),
      );
      expect(
        await resolve(tester, speed: AnimationSpeed.fast),
        MotionTokens.medium * (250 / 350),
      );
    });

    testWidgets('the gate wins over the speed', (tester) async {
      expect(
        await resolve(tester, reduce: true, speed: AnimationSpeed.slow),
        Duration.zero,
      );
    });

    testWidgets('sheets, dialogs and snackbars follow the speed', (
      tester,
    ) async {
      late BuildContext host;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) {
              host = context;
              return const SizedBox.shrink();
            },
          ),
          speed: AnimationSpeed.slow,
        ),
      );
      const factor = 450 / 350;

      late BuildContext sheet;
      unawaited(
        showAppBottomSheet<void>(
          context: host,
          builder: (context) {
            sheet = context;
            return const SizedBox(height: 100);
          },
        ),
      );
      await tester.pumpAndSettle();
      final (sheetIn, sheetCurve) = MotionTokens.springCurve(
        host,
        MotionSpring.spatialDefault,
      );
      final normalSheet = SpringCurve(
        SpringDescription.withDampingRatio(
          mass: 1,
          stiffness: MotionSpring.spatialDefault.stiffness,
          ratio: MotionSpring.spatialDefault.dampingRatio,
        ),
      ).settleDuration;
      expect(
        sheetIn.inMicroseconds,
        closeTo(normalSheet.inMicroseconds * factor, 2000),
      );
      final sheetRoute = ModalRoute.of(sheet)! as ModalBottomSheetRoute<void>;
      expect(sheetRoute.transitionDuration, sheetIn);
      expect(
        sheetRoute.reverseTransitionDuration,
        MotionTokens.medium * factor,
      );
      expect(sheetRoute.sheetAnimationStyle!.curve, isA<SpringCurve>());
      expect(sheetCurve, isA<SpringCurve>());
      Navigator.of(sheet).pop();
      await tester.pumpAndSettle();

      late BuildContext dialog;
      unawaited(
        showAppDialog<void>(
          context: host,
          builder: (context) {
            dialog = context;
            return const SizedBox(height: 100);
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(
        ModalRoute.of(dialog)!.transitionDuration,
        MotionTokens.dialog * factor,
      );
      Navigator.of(dialog).pop();
      await tester.pumpAndSettle();

      final style = snackBarAnimationStyleFor(host);
      expect(style.duration, MotionTokens.medium * factor);
      expect(style.reverseDuration, MotionTokens.fast * factor);
    });

    testWidgets('plays when neither source asks for reduction', (tester) async {
      expect(await resolve(tester), MotionTokens.medium);
    });

    testWidgets('collapses under the in-app reduce-motion setting', (
      tester,
    ) async {
      expect(await resolve(tester, reduce: true), Duration.zero);
    });

    testWidgets('collapses under platform disableAnimations', (tester) async {
      expect(await resolve(tester, platformDisable: true), Duration.zero);
    });

    testWidgets('collapses when both sources ask', (tester) async {
      expect(
        await resolve(tester, reduce: true, platformDisable: true),
        Duration.zero,
      );
    });

    testWidgets('collapses under platform reduceMotion (iOS hole)', (
      tester,
    ) async {
      // iOS "Reduce Motion" sets AccessibilityFeatures.reduceMotion WITHOUT
      // raising disableAnimations — the gate must read it directly or those
      // users get full animation.
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      bool? gate;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) {
              gate = MotionTokens.enabled(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(gate, isFalse);
      expect(await resolve(tester), Duration.zero);
    });
  });

  group('spring tokens', () {
    SpringCurve curveOf(MotionSpring token) => SpringCurve(
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: token.stiffness,
        ratio: token.dampingRatio,
      ),
    );

    test('a spring curve starts at 0 and ends exactly at 1', () {
      for (final token in MotionSpring.values) {
        final curve = curveOf(token);
        expect(curve.transform(0), 0, reason: token.name);
        expect(curve.transform(1), 1, reason: token.name);
        // Within the settle tolerance just before the end.
        expect(curve.transform(0.999), closeTo(1, 0.002), reason: token.name);
      }
    });

    test('a stiffer spring settles sooner', () {
      expect(
        curveOf(MotionSpring.spatialFast).settleDuration,
        lessThan(curveOf(MotionSpring.spatialDefault).settleDuration),
      );
    });

    test('only the expressive spring overshoots', () {
      double peak(MotionSpring token) {
        final curve = curveOf(token);
        return [
          for (var i = 0; i <= 200; i++) curve.transform(i / 200),
        ].reduce((a, b) => a > b ? a : b);
      }

      expect(peak(MotionSpring.expressiveSpatialFast), greaterThan(1.05));
      expect(peak(MotionSpring.effectsFast), lessThanOrEqualTo(1.0));
    });

    Future<(Duration, Curve)> springCurveAt(
      WidgetTester tester, {
      AnimationSpeed speed = AnimationSpeed.normal,
      bool reduce = false,
    }) async {
      (Duration, Curve)? resolved;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) {
              resolved = MotionTokens.springCurve(
                context,
                MotionSpring.spatialDefault,
              );
              return const SizedBox.shrink();
            },
          ),
          speed: speed,
          reduce: reduce,
        ),
      );
      return resolved!;
    }

    testWidgets('the slow speed stretches the settle time', (tester) async {
      final (normal, _) = await springCurveAt(tester);
      final (slow, _) = await springCurveAt(tester, speed: AnimationSpeed.slow);
      expect(
        slow.inMicroseconds / normal.inMicroseconds,
        closeTo(450 / 350, 450 / 350 * 0.02),
      );
    });

    testWidgets('reduced motion has no spring', (tester) async {
      final (duration, _) = await springCurveAt(tester, reduce: true);
      expect(duration, Duration.zero);
      SpringDescription? spring;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) {
              spring = MotionTokens.spring(context, MotionSpring.spatialFast);
              return const SizedBox.shrink();
            },
          ),
          reduce: true,
        ),
      );
      expect(spring, isNull);
    });
  });

  group('StaggeredEntrance', () {
    testWidgets('first-screen item fades in without moving', (tester) async {
      await tester.pumpWidget(
        _wrap(const StaggeredEntrance(index: 2, id: 2, child: Text('card'))),
      );
      final opacityFinder = find.descendant(
        of: find.byType(StaggeredEntrance),
        matching: find.byType(Opacity),
      );
      expect(opacityFinder, findsOneWidget);
      expect(tester.widget<Opacity>(opacityFinder).opacity, 0);
      final cardTop = tester.getTopLeft(find.text('card')).dy;

      // The exposure check defers the start to a post-frame callback; the
      // ticker's epoch is the following frame — one bare pump() arms it.
      await tester.pump();
      await tester.pump(
        MotionTokens.listStaggerStep * 2 + MotionTokens.listEntrance ~/ 2,
      );
      final midway = tester.widget<Opacity>(opacityFinder).opacity;
      expect(midway, greaterThan(0));
      expect(midway, lessThan(1));
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      expect(tester.getTopLeft(find.text('card')).dy, cardTop);

      await tester.pump(
        MotionTokens.listEntrance + MotionTokens.listStaggerStep * 3,
      );
      expect(tester.widget<Opacity>(opacityFinder).opacity, 1);
    });

    testWidgets('below-fold card waits for first viewport exposure', (
      tester,
    ) async {
      final played = <int>{};
      // SingleChildScrollView mounts every child eagerly — exactly the
      // "mounted but not exposed" state cacheExtent creates in a lazy list.
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            height: 300,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < 30; i++)
                    StaggeredEntrance(
                      index: i,
                      id: i,
                      played: played,
                      child: SizedBox(height: 200, child: Text('card $i')),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 300px viewport exposes only card 0 (+ the top sliver of card 1).
      // Below-fold cards are mounted but must NOT have played — their
      // entrance belongs to the moment the user scrolls to them.
      expect(find.text('card 3'), findsOneWidget); // mounted, off-viewport
      expect(played, isNot(contains(3)));

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
      expect(played, contains(3));
    });

    testWidgets('scroll-exposed card skips the first-screen stagger wait', (
      tester,
    ) async {
      final played = <int>{};
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            height: 300,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < 30; i++)
                    StaggeredEntrance(
                      index: i,
                      id: i,
                      played: played,
                      child: SizedBox(height: 200, child: Text('card $i')),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      // First-screen batch still staggers: card 1 (index 1 -> 30ms delay)
      // holds opacity 0 through its delay window before rising.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      final card1Opacity = find.descendant(
        of: find.widgetWithText(StaggeredEntrance, 'card 1'),
        matching: find.byType(Opacity),
      );
      expect(tester.widget<Opacity>(card1Opacity).opacity, 0);
      await tester.pumpAndSettle();

      // A calm scroll exposes card 9 — a continued-scrolling reveal, not
      // the opening batch. The 8x30ms wait must be gone: once the gate
      // fires, the entrance rises immediately (the old code still held
      // 0.0 inside its 240ms delay window at this point).
      tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .jumpTo(1700);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final card9Opacity = find.descendant(
        of: find.widgetWithText(StaggeredEntrance, 'card 9'),
        matching: find.byType(Opacity),
      );
      expect(tester.widget<Opacity>(card9Opacity).opacity, greaterThan(0.2));
      await tester.pumpAndSettle();
      expect(played, contains(9));
    });

    testWidgets('a card exposed mid-fling appears static immediately', (
      tester,
    ) async {
      final played = <int>{};
      await tester.pumpWidget(
        _wrap(
          SingleChildScrollView(
            child: Column(
              children: [
                for (var i = 0; i < 60; i++)
                  StaggeredEntrance(
                    index: i,
                    id: i,
                    played: played,
                    child: SizedBox(height: 200, child: Text('card $i')),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final firstViewport = Set<int>.of(played);
      expect(firstViewport, isNotEmpty);

      // Hard fling: cards entering the viewport mid-flight must render
      // static *right away* — staying at Opacity(0) for the rest of the
      // fling was the transparent-card bug. `played` grows during the
      // fling itself rather than at the settle edge.
      await tester.fling(
        find.byType(SingleChildScrollView),
        const Offset(0, -400),
        8000,
      );
      await tester.pump(const Duration(milliseconds: 80));
      final midFling = Set<int>.of(played);
      expect(midFling.length, greaterThan(firstViewport.length));
    });

    testWidgets('reduced motion renders without animation', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const StaggeredEntrance(index: 0, id: 0, child: Text('card')),
          reduce: true,
        ),
      );
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
    });

    testWidgets('frozen tickers render the end state and mark played', (
      tester,
    ) async {
      final played = <int>{};
      Widget frozen() => TickerMode(
        enabled: false,
        child: _wrap(
          StaggeredEntrance(
            index: 0,
            id: 0,
            played: played,
            child: Text('card'),
          ),
        ),
      );
      await tester.pumpWidget(frozen());
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
      expect(find.text('card'), findsOneWidget);
      expect(played, contains(0));

      // Tickers re-enabled after the transition: the item stays at the end
      // state instead of replaying a frozen half-entrance.
      await tester.pumpWidget(
        _wrap(
          StaggeredEntrance(
            index: 0,
            id: 0,
            played: played,
            child: Text('card'),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
    });

    testWidgets('a remounted item does not replay once its id is played', (
      tester,
    ) async {
      final played = <int>{};
      Widget item(String mount) => _wrap(
        StaggeredEntrance(
          key: ValueKey(mount),
          index: 0,
          id: 0,
          played: played,
          child: Text('card'),
        ),
      );
      await tester.pumpWidget(item('first'));
      await tester.pumpAndSettle();
      expect(played, contains(0));

      // The feed drops keep-alives: scrolling out and back mounts a fresh
      // State — the played set must suppress a second entrance.
      await tester.pumpWidget(item('second'));
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
    });

    testWidgets('a finished entrance keeps the card subtree on rebuild', (
      tester,
    ) async {
      var mounts = 0;
      Widget item() => _wrap(
        StaggeredEntrance(
          index: 0,
          id: 0,
          played: <int>{},
          child: _MountCounter(onMount: () => mounts++),
        ),
      );
      await tester.pumpWidget(item());
      await tester.pumpAndSettle();
      expect(mounts, 1);

      // A feed rebuild after the entrance settled: the card must be
      // updated in place, not re-inflated, and must not replay.
      await tester.pumpWidget(item());
      await tester.pump(const Duration(milliseconds: 16));
      expect(mounts, 1);
      expect(
        tester
            .widget<Opacity>(
              find.descendant(
                of: find.byType(StaggeredEntrance),
                matching: find.byType(Opacity),
              ),
            )
            .opacity,
        1,
      );
    });

    testWidgets('a refresh move keeps played: same id at a new index', (
      tester,
    ) async {
      final played = <int>{};
      await tester.pumpWidget(
        _wrap(
          StaggeredEntrance(
            index: 0,
            id: 7,
            played: played,
            child: const Text('card'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(played, contains(7));

      // A head-inserted refresh shifts every position: the surviving entity
      // arrives at index 3 but must not replay — its id is already played.
      await tester.pumpWidget(
        _wrap(
          StaggeredEntrance(
            index: 3,
            id: 7,
            played: played,
            child: const Text('card'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester
            .widget<Opacity>(
              find.descendant(
                of: find.byType(StaggeredEntrance),
                matching: find.byType(Opacity),
              ),
            )
            .opacity,
        1,
      );

      // A genuinely new entity at a replayable position still animates —
      // refresh inserts float in while survivors stay put.
      await tester.pumpWidget(
        _wrap(
          StaggeredEntrance(
            index: 0,
            id: 8,
            played: played,
            child: const Text('new'),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(Opacity),
        ),
        findsOneWidget,
      );
    });
  });

  group('PressScale', () {
    testWidgets('pointer down springs to pressScale, up springs back', (
      tester,
    ) async {
      // The child must be hit-testable: a bare SizedBox/ColoredBox is not
      // (hitTestSelf returns false), so the Listener never sees the pointer.
      // Real callers are always opaque card content — Text stands in here.
      await tester.pumpWidget(
        _wrap(const PressScale(child: Text('card content'))),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PressScale)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final mid = _pressScale(tester);
      expect(mid, lessThan(1));
      expect(mid, greaterThan(MotionTokens.pressScale));
      await tester.pumpAndSettle();
      expect(_pressScale(tester), MotionTokens.pressScale);

      await gesture.up();
      await tester.pumpAndSettle();
      // Exactly 1 at rest: a near-1 scale keeps a non-identity transform.
      expect(_pressScale(tester), 1);
    });

    testWidgets('a quick release reverses from the current scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const PressScale(child: Text('card content'))),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PressScale)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final released = _pressScale(tester);
      expect(released, lessThan(1));
      await gesture.up();

      // Frame by frame: no jump back to 1 or to the pressed rest, and the
      // scale keeps heading home once it turns around.
      final frames = <double>[released];
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        frames.add(_pressScale(tester));
      }
      for (var i = 1; i < frames.length; i++) {
        expect(
          (frames[i] - frames[i - 1]).abs(),
          lessThan(0.01),
          reason: 'frame $i jumped',
        );
      }
      final lowest = frames.reduce((a, b) => a < b ? a : b);
      final turn = frames.indexOf(lowest);
      // Damping ratio 0.9 overshoots 1 by ~1e-5 before snapping to it.
      for (var i = turn + 1; i < frames.length; i++) {
        expect(frames[i], greaterThanOrEqualTo(frames[i - 1] - 1e-4));
      }
      expect(frames.last, 1);
    });

    testWidgets('reduced motion snaps the scale without a flight', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const PressScale(child: Text('card content')), reduce: true),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PressScale)),
      );
      await tester.pump();
      expect(_pressScale(tester), MotionTokens.pressScale);
      await gesture.up();
      await tester.pump();
      expect(_pressScale(tester), 1.0);
    });

    testWidgets('the press-feedback setting turns the scale off', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MotionScope(
            reduce: false,
            pressFeedback: false,
            child: const Scaffold(
              body: PressScale(child: Text('card content')),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PressScale)),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(PressScale),
          matching: find.byType(ScaleTransition),
        ),
        findsNothing,
      );
      await gesture.up();
    });

    Widget scrollingCard() => _wrap(
      ListView(
        children: [
          const PressScale(
            // Opaque + tall: stays hit-testable and mounted after the
            // drag scrolls it partway up the viewport.
            child: ColoredBox(
              color: Colors.white,
              child: SizedBox(height: 100, child: Text('card content')),
            ),
          ),
          for (var i = 0; i < 40; i++)
            SizedBox(height: 60, child: Text('row $i')),
        ],
      ),
    );

    testWidgets('inside a scrollable a swipe never shows the press', (
      tester,
    ) async {
      await tester.pumpWidget(scrollingCard());
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PressScale)),
      );
      await tester.pump(kPressTimeout ~/ 2);
      expect(_pressScale(tester), 1.0);

      // The drag claims the pointer before the deadline: the pending press
      // is dropped, not shown late.
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump(kPressTimeout);
      expect(_pressScale(tester), 1.0);
      await gesture.up();
    });

    testWidgets('a scroll takeover releases the pressed scale', (tester) async {
      await tester.pumpWidget(scrollingCard());
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PressScale)),
      );
      // A held finger presses once the deadline passes.
      await tester.pump(kPressTimeout);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_pressScale(tester), closeTo(MotionTokens.pressScale, 1e-3));

      // The drag becomes a scroll: the ListView's recognizer claims the
      // pointer and the press springs back while the finger is still down.
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_pressScale(tester), closeTo(1, 1e-3));
      await gesture.up();
    });

    testWidgets('frozen tickers force the neutral scale', (tester) async {
      var tickers = true;
      Widget app() => TickerMode(
        enabled: tickers,
        child: _wrap(const PressScale(child: Text('card content'))),
      );
      await tester.pumpWidget(app());
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PressScale)),
      );
      await tester.pumpAndSettle();
      expect(_pressScale(tester), closeTo(MotionTokens.pressScale, 1e-3));

      // Route transition owns the ticker budget: the armed press scale must
      // not bake into the outgoing snapshot.
      tickers = false;
      await tester.pumpWidget(app());
      expect(_pressScale(tester), 1.0);
      await gesture.up();
    });
  });

  group('StateIconSwitcher', () {
    Widget switcher(bool selected) => StateIconSwitcher(
      value: selected,
      child: Icon(selected ? Icons.check_circle : Icons.circle_outlined),
    );

    /// Scale and opacity wrapped around the icon drawn for [icon].
    (double, double) entering(WidgetTester tester, IconData icon) {
      final scale = tester.widget<ScaleTransition>(
        find
            .ancestor(
              of: find.byIcon(icon),
              matching: find.byType(ScaleTransition),
            )
            .first,
      );
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byIcon(icon),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      return (scale.scale.value, fade.opacity.value);
    }

    testWidgets('the first build shows the icon at rest', (tester) async {
      await tester.pumpWidget(_wrap(switcher(false)));
      expect(entering(tester, Icons.circle_outlined), (1.0, 1.0));
    });

    testWidgets('a state change scales the new icon up from 0.8 and fades '
        'it in over the effectsFast spring', (tester) async {
      await tester.pumpWidget(_wrap(switcher(false)));
      await tester.pumpWidget(_wrap(switcher(true)));

      final (startScale, startOpacity) = entering(tester, Icons.check_circle);
      expect(startScale, StateIconSwitcher.enterScale);
      expect(startOpacity, 0);

      await tester.pump(const Duration(milliseconds: 40));
      final (midScale, midOpacity) = entering(tester, Icons.check_circle);
      expect(midScale, inExclusiveRange(StateIconSwitcher.enterScale, 1));
      expect(midOpacity, inExclusiveRange(0, 1));
      expect(find.byIcon(Icons.circle_outlined), findsOneWidget);

      // effectsFast settles in ~150 ms.
      await tester.pump(const Duration(milliseconds: 130));
      expect(find.byIcon(Icons.circle_outlined), findsNothing);
      expect(entering(tester, Icons.check_circle), (1.0, 1.0));
    });

    testWidgets('a rebuild with the same state does not swap', (tester) async {
      await tester.pumpWidget(_wrap(switcher(true)));
      await tester.pumpWidget(_wrap(switcher(true)));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(entering(tester, Icons.check_circle), (1.0, 1.0));
    });

    testWidgets('reduced motion swaps at once', (tester) async {
      await tester.pumpWidget(_wrap(switcher(false), reduce: true));
      await tester.pumpWidget(_wrap(switcher(true), reduce: true));
      await tester.pump();
      expect(find.byIcon(Icons.circle_outlined), findsNothing);
      expect(entering(tester, Icons.check_circle), (1.0, 1.0));
    });
  });

  group('Removable', () {
    Widget list(
      RemovalController controller,
      List<String> ids, {
      RemovalStyle style = RemovalStyle.row,
      bool reduce = false,
    }) => _wrap(
      RemovalScope(
        controller: controller,
        child: ListView(
          children: [
            for (final id in ids)
              Removable(
                id: id,
                style: style,
                child: SizedBox(height: 50, child: Text(id)),
              ),
          ],
        ),
      ),
      reduce: reduce,
    );

    double opacity(WidgetTester tester, String id) => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.text(id),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;

    testWidgets('a row collapses and fades before the commit, and the '
        'exit future waits for it', (tester) async {
      final controller = RemovalController();
      await tester.pumpWidget(list(controller, ['a', 'b']));
      final bTop = tester.getTopLeft(find.text('b')).dy;

      var done = false;
      unawaited(controller.playExit(['a']).then((_) => done = true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(done, isFalse);
      expect(tester.getTopLeft(find.text('b')).dy, lessThan(bTop));
      expect(opacity(tester, 'a'), inExclusiveRange(0, 1));

      // spatialFast settles in ~225 ms.
      await tester.pump(const Duration(milliseconds: 200));
      expect(done, isTrue);
      expect(tester.getTopLeft(find.text('b')).dy, bTop - 50);
      expect(opacity(tester, 'b'), 1);
    });

    testWidgets('restore brings a row back after a failed commit', (
      tester,
    ) async {
      final controller = RemovalController();
      await tester.pumpWidget(list(controller, ['a', 'b']));
      final bTop = tester.getTopLeft(find.text('b')).dy;
      unawaited(controller.playExit(['a']));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('b')).dy, bTop - 50);

      controller.restore(['a']);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('b')).dy, bTop);
      expect(opacity(tester, 'a'), 1);
    });

    testWidgets('a tile shrinks to 0.9 and fades out', (tester) async {
      final controller = RemovalController();
      await tester.pumpWidget(
        list(controller, ['a'], style: RemovalStyle.tile),
      );
      unawaited(controller.playExit(['a']));
      await tester.pumpAndSettle();
      final scale = tester.widget<ScaleTransition>(
        find
            .ancestor(
              of: find.text('a'),
              matching: find.byType(ScaleTransition),
            )
            .first,
      );
      expect(scale.scale.value, 0.9);
      expect(opacity(tester, 'a'), 0);
      // A tile keeps its cell: the grid reflows on the commit.
      expect(tester.getSize(find.text('a')).height, 50);
    });

    testWidgets('reduced motion and ids off screen complete at once', (
      tester,
    ) async {
      final controller = RemovalController();
      await tester.pumpWidget(list(controller, ['a', 'b'], reduce: true));
      final bTop = tester.getTopLeft(find.text('b')).dy;

      var done = false;
      unawaited(controller.playExit(['a', 'gone']).then((_) => done = true));
      await tester.pump();
      expect(done, isTrue);
      expect(tester.getTopLeft(find.text('b')).dy, bTop - 50);
    });

    testWidgets('a recycled slot showing another id starts present', (
      tester,
    ) async {
      final controller = RemovalController();
      await tester.pumpWidget(list(controller, ['a', 'b']));
      unawaited(controller.playExit(['a']));
      await tester.pumpAndSettle();

      // The commit drops 'a': its unkeyed slot now shows 'b'.
      await tester.pumpWidget(list(controller, ['b']));
      expect(opacity(tester, 'b'), 1);
      expect(tester.getSize(find.text('b')).height, 50);
    });

    testWidgets('a row disposed mid-exit does not leave the exit hanging', (
      tester,
    ) async {
      final controller = RemovalController();
      await tester.pumpWidget(list(controller, ['a', 'b']));
      var done = false;
      unawaited(controller.playExit(['a']).then((_) => done = true));
      await tester.pump(const Duration(milliseconds: 60));

      await tester.pumpWidget(_wrap(const SizedBox.shrink()));
      await tester.pump();
      expect(done, isTrue);
    });

    Widget inserted(
      RemovalController controller, {
      bool reduce = false,
    }) => _wrap(
      RemovalScope(
        controller: controller,
        // A Column: a lazy list counts the zero-height first frame offstage.
        child: Column(
          children: const [
            Removable(
              id: 'new',
              animateIn: true,
              child: SizedBox(height: 50, child: Text('new')),
            ),
            SizedBox(height: 50, child: Text('below')),
          ],
        ),
      ),
      reduce: reduce,
    );

    testWidgets('an inserted row grows in and fades from zero', (tester) async {
      await tester.pumpWidget(inserted(RemovalController()));
      final belowTop = tester.getTopLeft(find.text('below')).dy;
      expect(opacity(tester, 'new'), 0);

      await tester.pump(const Duration(milliseconds: 60));
      expect(opacity(tester, 'new'), inExclusiveRange(0, 1));
      expect(tester.getTopLeft(find.text('below')).dy, greaterThan(belowTop));

      await tester.pumpAndSettle();
      expect(opacity(tester, 'new'), 1);
      expect(tester.getTopLeft(find.text('below')).dy, belowTop + 50);
    });

    testWidgets('reduced motion inserts the row at full size', (tester) async {
      await tester.pumpWidget(inserted(RemovalController(), reduce: true));
      await tester.pump();
      expect(opacity(tester, 'new'), 1);
      expect(tester.getSize(find.text('new')).height, 50);
    });
  });

  group('StateFade', () {
    Widget faded(Object kind, {bool reduce = false}) => _wrap(
      StateFade(kind: kind, child: Text('$kind')),
      reduce: reduce,
    );

    double opacity(WidgetTester tester, String text) => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.text(text),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;

    testWidgets('the first build shows its state at once', (tester) async {
      await tester.pumpWidget(faded('skeleton'));
      expect(opacity(tester, 'skeleton'), 1);
    });

    testWidgets('a kind change fades the new state in from zero over the '
        'effectsFast spring', (tester) async {
      await tester.pumpWidget(faded('skeleton'));
      await tester.pumpWidget(faded('content'));
      expect(find.text('skeleton'), findsNothing, reason: 'no cross-fade');
      expect(opacity(tester, 'content'), 0);

      await tester.pump(const Duration(milliseconds: 40));
      expect(opacity(tester, 'content'), inExclusiveRange(0, 1));

      // effectsFast settles in ~150 ms.
      await tester.pump(const Duration(milliseconds: 130));
      expect(opacity(tester, 'content'), 1);
    });

    testWidgets('a rebuild of the same kind does not fade', (tester) async {
      await tester.pumpWidget(faded('content'));
      await tester.pumpWidget(faded('content'));
      expect(opacity(tester, 'content'), 1);
    });

    testWidgets('onMount fades in on the first build', (tester) async {
      await tester.pumpWidget(
        _wrap(const StateFade.onMount(child: Text('empty'))),
      );
      expect(opacity(tester, 'empty'), 0);
      await tester.pumpAndSettle();
      expect(opacity(tester, 'empty'), 1);
    });

    testWidgets('reduced motion and frozen tickers show the state at once', (
      tester,
    ) async {
      await tester.pumpWidget(faded('skeleton', reduce: true));
      await tester.pumpWidget(faded('content', reduce: true));
      expect(opacity(tester, 'content'), 1);

      await tester.pumpWidget(
        _wrap(
          const TickerMode(
            enabled: false,
            child: StateFade.onMount(child: Text('error')),
          ),
        ),
      );
      expect(opacity(tester, 'error'), 1);
    });
  });

  group('SpringSize', () {
    Widget section(bool open, {bool reduce = false}) => _wrap(
      Column(
        children: [
          SpringSize(
            child: open
                ? const SizedBox(height: 100, width: 10)
                : const SizedBox.shrink(),
          ),
          const Text('below'),
        ],
      ),
      reduce: reduce,
    );

    testWidgets('opening and closing animate the height', (tester) async {
      await tester.pumpWidget(section(false));
      final closedTop = tester.getTopLeft(find.text('below')).dy;

      await tester.pumpWidget(section(true));
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        tester.getTopLeft(find.text('below')).dy,
        inExclusiveRange(closedTop, closedTop + 100),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('below')).dy, closedTop + 100);

      await tester.pumpWidget(section(false));
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        tester.getTopLeft(find.text('below')).dy,
        inExclusiveRange(closedTop, closedTop + 100),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('below')).dy, closedTop);
    });

    testWidgets('reduced motion resizes at once', (tester) async {
      await tester.pumpWidget(section(false, reduce: true));
      final closedTop = tester.getTopLeft(find.text('below')).dy;
      await tester.pumpWidget(section(true, reduce: true));
      await tester.pump();
      expect(tester.getTopLeft(find.text('below')).dy, closedTop + 100);
    });
  });

  group('DragToDismiss', () {
    double dragOffset(WidgetTester tester) {
      // The outer Transform is the translate; the inner one is the scale.
      final transform = tester.widget<Transform>(
        find
            .descendant(
              of: find.byType(DragToDismiss),
              matching: find.byType(Transform),
            )
            .first,
      );
      return transform.transform.getTranslation().y;
    }

    /// A short downward pull released with a decayed velocity: below both
    /// dismissDistance and dismissVelocity, so the surface cancels back.
    Future<void> dragDownAndRelease(WidgetTester tester) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(DragToDismiss)),
      );
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();
      // Let the release velocity decay under dismissVelocity so the drag
      // returns instead of dismissing.
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
    }

    testWidgets('crossing the dismiss distance is felt both ways', (
      tester,
    ) async {
      final haptics = recordHaptics();
      await tester.pumpWidget(
        _wrap(
          DragToDismiss(
            onDismissed: () {},
            child: const SizedBox.expand(child: Text('viewer')),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(DragToDismiss)),
      );
      // Past the touch slop, still under the 160 distance.
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      expect(haptics.played, isEmpty);
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      expect(haptics.roles, [HapticRole.thresholdOn]);
      // Moving further past it stays quiet.
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(haptics.roles, [HapticRole.thresholdOn]);

      // The throttle reads the wall clock; let the light lane re-arm.
      await tester.runAsync(
        () => Future<void>.delayed(AppHaptics.lightInterval),
      );
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump();
      expect(haptics.roles, [HapticRole.thresholdOn, HapticRole.thresholdOff]);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('default motion returns the surface with a flight', (
      tester,
    ) async {
      var dismissed = false;
      await tester.pumpWidget(
        _wrap(
          DragToDismiss(
            onDismissed: () => dismissed = true,
            child: const SizedBox.expand(child: Text('viewer')),
          ),
        ),
      );
      await dragDownAndRelease(tester);
      // Release frame: the return flight is armed but has not ticked yet —
      // the offset still sits at the released 80.
      await tester.pump();
      expect(dragOffset(tester), 80);
      // Mid-flight: the offset is between the released 80 and the 0 target.
      await tester.pump(const Duration(milliseconds: 90));
      final mid = dragOffset(tester);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(80));
      expect(dismissed, isFalse);
      await tester.pumpAndSettle();
      expect(dragOffset(tester), 0);
    });

    testWidgets('the return spring starts at the release velocity', (
      tester,
    ) async {
      var dismissed = false;
      await tester.pumpWidget(
        _wrap(
          DragToDismiss(
            onDismissed: () => dismissed = true,
            child: const SizedBox.expand(child: Text('viewer')),
          ),
        ),
      );

      /// Offset 16 ms into the return from a release at 80.
      Future<double> returnAfterRelease() async {
        await tester.pump();
        expect(dragOffset(tester), 80);
        await tester.pump(const Duration(milliseconds: 16));
        final offset = dragOffset(tester);
        await tester.pumpAndSettle();
        expect(dragOffset(tester), 0);
        return offset;
      }

      // Still release: the velocity decays before the finger lifts.
      await dragDownAndRelease(tester);
      final still = await returnAfterRelease();

      // A steady ~500 px/s downward pull: under the 1000 px/s dismiss
      // velocity and the 160 dismiss distance, so the surface returns —
      // but the spring starts with the finger's downward speed.
      final gesture = await tester.createGesture();
      await gesture.down(tester.getCenter(find.byType(DragToDismiss)));
      for (var i = 1; i <= 8; i++) {
        await gesture.moveBy(
          const Offset(0, 10),
          timeStamp: Duration(milliseconds: 20 * i),
        );
        await tester.pump();
      }
      await gesture.up(timeStamp: const Duration(milliseconds: 170));
      final moving = await returnAfterRelease();

      expect(moving, greaterThan(still + 4));
      expect(dismissed, isFalse);
    });

    testWidgets('reduced motion lands the canceled drag without a flight', (
      tester,
    ) async {
      var dismissed = false;
      await tester.pumpWidget(
        _wrap(
          DragToDismiss(
            onDismissed: () => dismissed = true,
            child: const SizedBox.expand(child: Text('viewer')),
          ),
          reduce: true,
        ),
      );
      await dragDownAndRelease(tester);
      await tester.pump();
      expect(dragOffset(tester), 0);
      expect(dismissed, isFalse);
    });
  });

  group('reduceMotion setting', () {
    test('defaults off and round-trips through JSON', () {
      expect(AppSettings.defaults().reduceMotion, isFalse);
      final stored = AppSettings.defaults().copyWith(reduceMotion: true);
      final restored = AppSettings.fromJson(
        stored.toJson(),
        fallback: AppSettings.defaults(),
      );
      expect(restored.reduceMotion, isTrue);
    });

    test('corrupt reduceMotion falls back to the base value', () {
      final restored = AppSettings.fromJson(const {
        'reduceMotion': 'yes',
      }, fallback: AppSettings.defaults().copyWith(reduceMotion: true));
      expect(restored.reduceMotion, isTrue);
    });
  });
}
