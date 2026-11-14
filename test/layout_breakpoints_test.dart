import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/layout/app_breakpoints.dart';
import 'package:parfait/app/layout/form_factor.dart';
import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/layout/two_pane.dart';
import 'package:parfait/app/layout/window_layout_spec.dart';
import 'package:parfait/app/navigation/home_shell_metrics.dart';
import 'package:parfait/core/settings/app_settings.dart';

void main() {
  group('AppBreakpoints', () {
    test('a phone is a display under the medium boundary', () {
      expect(AppBreakpoints.isPhoneDisplay(const Size(411, 896)), isTrue);
      // A foldable's cover screen; its unfolded inner screen.
      expect(AppBreakpoints.isPhoneDisplay(const Size(360, 748)), isTrue);
      expect(AppBreakpoints.isPhoneDisplay(const Size(673, 841)), isFalse);
      // No display size reported: decided by the window alone.
      expect(AppBreakpoints.isPhoneDisplay(null), isFalse);
    });

    test('two-pane detail needs a landscape area at least medium wide', () {
      // Landscape tablet or tall enough desktop window, less the rail.
      expect(AppBreakpoints.useTwoPaneDetail(const Size(896, 480)), isTrue);
      expect(AppBreakpoints.useTwoPaneDetail(const Size(919, 640)), isTrue);
      // Short phone landscape (< 480dp height), portrait tablet, unfolded
      // foldable, and landscape split screen keep single scroll.
      expect(AppBreakpoints.useTwoPaneDetail(const Size(896, 411)), isFalse);
      expect(AppBreakpoints.useTwoPaneDetail(const Size(720, 1280)), isFalse);
      expect(AppBreakpoints.useTwoPaneDetail(const Size(620, 840)), isFalse);
      expect(AppBreakpoints.useTwoPaneDetail(const Size(599, 300)), isFalse);
    });

    testWidgets('bounded detail overlay activates on large flat workspaces', (
      tester,
    ) async {
      Future<bool> check(
        Size content, {
        List<ui.DisplayFeature> features = const [],
      }) async {
        late bool result;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(size: content, displayFeatures: features),
            child: Builder(
              builder: (context) {
                result = AppBreakpoints.useBoundedDetailOverlayOf(
                  context,
                  content,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        return result;
      }

      expect(await check(const Size(960, 600)), isTrue);
      expect(await check(const Size(959, 600)), isFalse);
      expect(await check(const Size(960, 599)), isFalse);
      expect(
        await check(
          const Size(1200, 800),
          features: const [
            ui.DisplayFeature(
              bounds: Rect.fromLTWH(594, 0, 12, 800),
              type: ui.DisplayFeatureType.hinge,
              state: ui.DisplayFeatureState.postureHalfOpened,
            ),
          ],
        ),
        isFalse,
      );
    });
  });

  group('FormFactor', () {
    FormFactor form(
      Size? display,
      TargetPlatform platform, [
      InterfaceForm choice = InterfaceForm.auto,
    ]) => FormFactor.resolve(
      display: display,
      platform: platform,
      choice: choice,
    );
    const phone = Size(411, 896);
    const tablet = Size(1280, 800);

    test('a phone, a touch screen or a PC, by display and platform', () {
      expect(form(phone, TargetPlatform.android), FormFactor.phone);
      expect(form(tablet, TargetPlatform.android), FormFactor.touch);
      expect(form(null, TargetPlatform.android), FormFactor.touch);
      expect(form(tablet, TargetPlatform.windows), FormFactor.pc);
      // A desktop asked for the touch shell (a Windows tablet).
      expect(
        form(tablet, TargetPlatform.windows, InterfaceForm.touch),
        FormFactor.touch,
      );
      // Only desktops offer the choice; one restored from a desktop's
      // backup does not turn a tablet into a PC.
      expect(
        form(tablet, TargetPlatform.android, InterfaceForm.pc),
        FormFactor.touch,
      );
    });

    test('the rail engages at the medium boundary, never on a phone', () {
      expect(FormFactor.touch.hasRail(599), isFalse);
      expect(FormFactor.touch.hasRail(600), isTrue);
      expect(FormFactor.pc.hasRail(600), isTrue);
      expect(FormFactor.phone.hasRail(1200), isFalse);
    });

    test("a PC's rail opens from extra-large until the user toggles it; "
        'a large touch rail opens only when requested', () {
      expect(FormFactor.pc.railExpanded(1599, choice: null), isFalse);
      expect(FormFactor.pc.railExpanded(1600, choice: null), isTrue);
      expect(FormFactor.pc.railExpanded(1920, choice: false), isFalse);
      expect(FormFactor.pc.railExpanded(800, choice: true), isTrue);
      // Touch defaults collapsed; expanded-size touch allows explicit toggle.
      expect(FormFactor.touch.canToggleRail(840, height: 480), isTrue);
      expect(FormFactor.touch.canToggleRail(839, height: 600), isFalse);
      expect(FormFactor.touch.canToggleRail(1000, height: 479), isFalse);
      expect(FormFactor.touch.railExpanded(1920, choice: null), isFalse);
      expect(
        FormFactor.touch.railExpanded(1920, height: 900, choice: true),
        isTrue,
      );
      expect(
        FormFactor.touch.railExpanded(700, height: 900, choice: true),
        isFalse,
      );
      expect(
        FormFactor.touch.railExpanded(1000, height: 411, choice: true),
        isFalse,
      );
    });
  });

  group('TwoPane', () {
    testWidgets('renders primary and secondary side by side', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        const MaterialApp(
          home: TwoPane(
            primary: Placeholder(key: Key('p')),
            secondary: Placeholder(key: Key('s')),
          ),
        ),
      );
      expect(
        tester.getRect(find.byKey(const Key('p'))).right,
        tester.getRect(find.byKey(const Key('s'))).left,
      );
    });

    testWidgets('the secondary column stays between its bounds', (
      tester,
    ) async {
      Future<double> secondaryWidth(double width) async {
        await tester.binding.setSurfaceSize(Size(width, 600));
        await tester.pumpWidget(
          const MaterialApp(
            home: TwoPane(
              primary: Placeholder(key: Key('p')),
              secondary: Placeholder(key: Key('s')),
            ),
          ),
        );
        return tester.getSize(find.byKey(const Key('s'))).width;
      }

      addTearDown(() => tester.binding.setSurfaceSize(null));
      expect(await secondaryWidth(815), 320);
      expect(await secondaryWidth(1000), moreOrLessEquals(380));
      expect(await secondaryWidth(1440), 480);
    });

    testWidgets('AdaptiveTwoPane avoids vertical book hinge including rail', (
      tester,
    ) async {
      const surface = Size(960, 740);
      const hinge = ui.DisplayFeature(
        bounds: Rect.fromLTWH(474, 0, 12, 740),
        type: ui.DisplayFeatureType.hinge,
        state: ui.DisplayFeatureState.postureHalfOpened,
      );
      await tester.binding.setSurfaceSize(surface);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: surface, displayFeatures: [hinge]),
          child: MaterialApp(
            home: HomeShellChrome(
              bottomBarExtent: 0,
              railExtent: 72,
              bottomBarVisibleExtent: const AlwaysStoppedAnimation(0),
              bottomBarVisibility: const AlwaysStoppedAnimation(0),
              onBranchRootScroll: (_) => false,
              child: const Padding(
                padding: EdgeInsets.only(left: 72),
                child: AdaptiveTwoPane(
                  persistenceKey: null,
                  primary: Placeholder(key: Key('p')),
                  secondary: Placeholder(key: Key('s')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.getRect(find.byKey(const Key('p'))).right, 474);
      expect(tester.getRect(find.byKey(const Key('s'))).left, 486);
    });

    testWidgets(
      'AdaptiveTwoPane book hinge aligns to rest origin across sliding route push',
      (tester) async {
        const surface = Size(884, 740);
        const hinge = ui.DisplayFeature(
          bounds: Rect.fromLTWH(436, 0, 12, 740),
          type: ui.DisplayFeatureType.hinge,
          state: ui.DisplayFeatureState.postureHalfOpened,
        );
        await tester.binding.setSurfaceSize(surface);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final navKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(size: surface, displayFeatures: [hinge]),
            child: MaterialApp(
              home: HomeShellChrome(
                bottomBarExtent: 0,
                railExtent: 88,
                bottomBarVisibleExtent: const AlwaysStoppedAnimation(0),
                bottomBarVisibility: const AlwaysStoppedAnimation(0),
                onBranchRootScroll: (_) => false,
                child: Padding(
                  padding: const EdgeInsets.only(left: 88),
                  child: Navigator(
                    key: navKey,
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        unawaited(
          navKey.currentState!.push(
            PageRouteBuilder<void>(
              transitionDuration: const Duration(milliseconds: 300),
              pageBuilder: (context, animation, secondaryAnimation) => Scaffold(
                appBar: AppBar(title: const Text('t')),
                body: const AdaptiveTwoPane(
                  persistenceKey: null,
                  primary: Placeholder(key: Key('p')),
                  secondary: Placeholder(key: Key('s')),
                ),
              ),
              transitionsBuilder:
                  (context, animation, secondaryAnimation, child) =>
                      SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(1, 0),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        await tester.pumpAndSettle();

        expect(tester.getRect(find.byKey(const Key('p'))).right, 436);
        expect(tester.getRect(find.byKey(const Key('s'))).left, 448);
      },
    );

    testWidgets('AdaptiveTwoPane splits vertically on tabletop hinge', (
      tester,
    ) async {
      const surface = Size(884, 740);
      const hinge = ui.DisplayFeature(
        bounds: Rect.fromLTWH(0, 364, 884, 12),
        type: ui.DisplayFeatureType.hinge,
        state: ui.DisplayFeatureState.postureHalfOpened,
      );
      await tester.binding.setSurfaceSize(surface);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(size: surface, displayFeatures: [hinge]),
          child: MaterialApp(
            home: AdaptiveTwoPane(
              persistenceKey: null,
              primary: Placeholder(key: Key('p')),
              secondary: Placeholder(key: Key('s')),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.getRect(find.byKey(const Key('p'))).bottom, 364);
      expect(tester.getRect(find.byKey(const Key('s'))).top, 376);
    });

    testWidgets('AdaptiveTwoPane pointer handle resizes and saves ratio', (
      tester,
    ) async {
      const surface = Size(1000, 700);
      const key = 'test.two_pane.resize';
      await tester.binding.setSurfaceSize(surface);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      Future<void> pumpPane() => tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(size: surface),
          child: InputModalityScope(
            initialModality: InputModality.pointer,
            child: MaterialApp(
              home: AdaptiveTwoPane(
                persistenceKey: key,
                primary: Placeholder(key: Key('p')),
                secondary: Placeholder(key: Key('s')),
              ),
            ),
          ),
        ),
      );

      await pumpPane();
      expect(tester.getSize(find.byKey(const Key('s'))).width, closeTo(380, 1));
      await tester.drag(
        find.byKey(const ValueKey('two-pane-resize-handle')),
        const Offset(-60, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      final resized = tester.getSize(find.byKey(const Key('s'))).width;
      expect(resized, greaterThan(410));

      // Remount picks up the session fraction immediately.
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPane();
      expect(tester.getSize(find.byKey(const Key('s'))).width, resized);
    });
  });

  group('WindowLayoutSpec', () {
    test('classifies width tiers and fold postures accurately', () {
      expect(WindowLayoutSpec.widthClassFor(599), WindowWidthClass.compact);
      expect(WindowLayoutSpec.widthClassFor(600), WindowWidthClass.medium);
      expect(WindowLayoutSpec.widthClassFor(840), WindowWidthClass.expanded);
      expect(WindowLayoutSpec.widthClassFor(1200), WindowWidthClass.large);
      expect(WindowLayoutSpec.widthClassFor(1600), WindowWidthClass.extraLarge);

      expect(
        WindowLayoutSpec.resolveFold(const Size(390, 844), const []).$1,
        FoldPosture.flat,
      );
      // Horizontal flip fold in flat posture does not enter tabletop.
      expect(
        WindowLayoutSpec.resolveFold(const Size(412, 915), const [
          ui.DisplayFeature(
            bounds: Rect.fromLTWH(0, 450, 412, 0),
            type: ui.DisplayFeatureType.fold,
            state: ui.DisplayFeatureState.postureFlat,
          ),
        ]).$1,
        FoldPosture.flat,
      );
      // Narrow vertical fold stays flat; expanded vertical hinge is book.
      expect(
        WindowLayoutSpec.resolveFold(const Size(500, 740), const [
          ui.DisplayFeature(
            bounds: Rect.fromLTWH(244, 0, 12, 740),
            type: ui.DisplayFeatureType.hinge,
            state: ui.DisplayFeatureState.postureHalfOpened,
          ),
        ]).$1,
        FoldPosture.flat,
      );
      expect(
        WindowLayoutSpec.resolveFold(const Size(884, 740), const [
          ui.DisplayFeature(
            bounds: Rect.fromLTWH(436, 0, 12, 740),
            type: ui.DisplayFeatureType.hinge,
            state: ui.DisplayFeatureState.postureHalfOpened,
          ),
        ]).$1,
        FoldPosture.book,
      );
      expect(
        WindowLayoutSpec.resolveFold(const Size(884, 740), const [
          ui.DisplayFeature(
            bounds: Rect.fromLTWH(0, 364, 884, 12),
            type: ui.DisplayFeatureType.hinge,
            state: ui.DisplayFeatureState.postureHalfOpened,
          ),
        ]).$1,
        FoldPosture.tabletop,
      );
      expect(AppBreakpoints.useTwoPaneDetail(const Size(840, 1000)), isTrue);
      expect(AppBreakpoints.useTwoPaneDetail(const Size(924, 1480)), isFalse);
      expect(
        AppBreakpoints.useTwoPaneDetail(
          const Size(640, 800),
          posture: FoldPosture.book,
        ),
        isTrue,
      );
    });
  });
}
