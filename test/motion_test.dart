import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pixiv_func/app/motion/drag_to_dismiss.dart';
import 'package:pixiv_func/app/motion/feed_entrance.dart';
import 'package:pixiv_func/app/motion/motion_tokens.dart';
import 'package:pixiv_func/app/motion/press_scale.dart';
import 'package:pixiv_func/app/theme/replica_theme.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';

Widget _wrap(
  Widget child, {
  bool reduce = false,
  bool platformDisable = false,
}) {
  final app = MaterialApp(
    theme: replicaTheme(Brightness.light),
    home: MotionScope(
      reduce: reduce,
      child: Scaffold(body: child),
    ),
  );
  if (!platformDisable) return app;
  return MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: app,
  );
}

/// The press contract is asserted on [AnimatedScale]'s target/duration
/// rather than the rendered Transform: in this test environment implicit
/// animations started by a widget update do not tick under `pump` (ones
/// started at widget creation do), so the matrix never leaves 1.0. The
/// state machine and token wiring are ours to test; interpolation is the
/// framework's.
AnimatedScale _animatedScale(WidgetTester tester) {
  return tester.widget<AnimatedScale>(
    find.descendant(
      of: find.byType(PressScale),
      matching: find.byType(AnimatedScale),
    ),
  );
}

void main() {
  group('MotionTokens gate', () {
    Future<Duration> resolve(
      WidgetTester tester, {
      bool reduce = false,
      bool platformDisable = false,
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
        ),
      );
      return resolved!;
    }

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

  group('StaggeredEntrance', () {
    testWidgets('first-screen item animates: rises then settles', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const StaggeredEntrance(index: 2, id: 2, child: Text('card'))),
      );
      final opacityFinder = find.descendant(
        of: find.byType(StaggeredEntrance),
        matching: find.byType(Opacity),
      );
      expect(opacityFinder, findsOneWidget);
      expect(tester.widget<Opacity>(opacityFinder).opacity, 0);

      // The exposure check defers the start to a post-frame callback; the
      // ticker's epoch is the following frame — one bare pump() arms it.
      await tester.pump();
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

    testWidgets('a rebuilt item does not replay once its id is played', (
      tester,
    ) async {
      final played = <int>{};
      Widget item() => _wrap(
        StaggeredEntrance(index: 0, id: 0, played: played, child: Text('card')),
      );
      await tester.pumpWidget(item());
      await tester.pumpAndSettle();
      expect(played, contains(0));

      // The feed drops keep-alives: scrolling out and back rebuilds the
      // widget — the played set must suppress a second entrance.
      await tester.pumpWidget(item());
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(Opacity),
        ),
        findsNothing,
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
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(Opacity),
        ),
        findsNothing,
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
    testWidgets('pointer down scales to pressScale, up releases', (
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
      expect(_animatedScale(tester).scale, MotionTokens.pressScale);
      expect(_animatedScale(tester).duration, MotionTokens.press);

      await gesture.up();
      await tester.pump();
      expect(_animatedScale(tester).scale, 1.0);
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
      expect(_animatedScale(tester).scale, MotionTokens.pressScale);
      expect(_animatedScale(tester).duration, Duration.zero);
      await gesture.up();
      await tester.pump();
      expect(_animatedScale(tester).scale, 1.0);
    });

    testWidgets('a scroll takeover releases the pressed scale', (tester) async {
      await tester.pumpWidget(
        _wrap(
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
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PressScale)),
      );
      await tester.pump();
      expect(_animatedScale(tester).scale, MotionTokens.pressScale);

      // The drag becomes a scroll: the ListView's recognizer wins the
      // arena, the tap recognizer is rejected, and onTapCancel releases
      // the scale — a raw Listener would stay pressed for the whole drag.
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();
      expect(_animatedScale(tester).scale, 1.0);
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
      await tester.pump();
      expect(_animatedScale(tester).scale, MotionTokens.pressScale);

      // Route transition owns the ticker budget: the armed press scale must
      // not bake into the outgoing snapshot.
      tickers = false;
      await tester.pumpWidget(app());
      expect(_animatedScale(tester).scale, 1.0);
      expect(_animatedScale(tester).duration, Duration.zero);
      await gesture.up();
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
