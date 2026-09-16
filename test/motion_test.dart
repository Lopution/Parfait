import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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
  });

  group('StaggeredEntrance', () {
    testWidgets('first-screen item animates: rises then settles', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const StaggeredEntrance(index: 2, child: Text('card'))),
      );
      final opacityFinder = find.descendant(
        of: find.byType(StaggeredEntrance),
        matching: find.byType(Opacity),
      );
      expect(opacityFinder, findsOneWidget);
      expect(tester.widget<Opacity>(opacityFinder).opacity, 0);

      await tester.pump(
        MotionTokens.listEntrance + MotionTokens.listStaggerStep * 3,
      );
      expect(tester.widget<Opacity>(opacityFinder).opacity, 1);
    });

    testWidgets('items at the entrance cap render without animation', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const StaggeredEntrance(
            index: MotionTokens.listEntranceMaxItems,
            child: Text('late card'),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(TweenAnimationBuilder<double>),
        ),
        findsNothing,
      );
      expect(find.text('late card'), findsOneWidget);
    });

    testWidgets('reduced motion renders without animation', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const StaggeredEntrance(index: 0, child: Text('card')),
          reduce: true,
        ),
      );
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(TweenAnimationBuilder<double>),
        ),
        findsNothing,
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
