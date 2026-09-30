import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pixiv_func/app/motion/motion_tokens.dart';
import 'package:pixiv_func/app/navigation/home_shell_metrics.dart';
import 'package:pixiv_func/app/widgets/app_snack_bar.dart';
import 'package:pixiv_func/app/widgets/func_bottom_nav.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

Widget _host(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      home: child,
    ),
  );
}

Widget _branchHost({required Widget child}) =>
    _host(BranchRootScaffold(branchIndex: 0, child: child));

Widget _triggerButton({SnackBarAction? action}) {
  // Branch children are Scaffolds (each feature page has an AppBar); the
  // branch messenger requires a descendant Scaffold to anchor to.
  return Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showAppSnackBar(context, '提示内容', action: action),
          child: const Text('show'),
        ),
      ),
    ),
  );
}

/// Branch page that ends with the shared nav-bar spacer, like every real
/// branch-root scrollable does.
Widget _shellPage() => Scaffold(
  body: Builder(
    builder: (context) => Column(
      children: [
        const Spacer(),
        TextButton(
          onPressed: () => showAppSnackBar(context, '提示内容'),
          child: const Text('show'),
        ),
        const Spacer(),
        const FuncNavBarSpacer(),
      ],
    ),
  ),
);

/// Mounts the real shell bar as an overlay sibling of the branch strip —
/// the same layering the home shell uses, with [HomeShellChrome] computed
/// the way [BranchSlideStack] computes it, so the bar's resting extent is
/// available on the first frame instead of a post-layout measurement.
Future<({ProviderContainer container, AnimationController scrollVisibility})>
_pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  final scrollVisibility = AnimationController(vsync: tester, value: 1);
  addTearDown(scrollVisibility.dispose);
  final visibleExtent = ValueNotifier<double>(0);
  addTearDown(visibleExtent.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        home: Builder(
          builder: (context) => HomeShellChrome(
            bottomBarExtent: FuncBottomNav.restingExtent(
              MediaQuery.paddingOf(context).bottom,
            ),
            bottomBarVisibleExtent: visibleExtent,
            child: Stack(
              children: [
                BranchRootScaffold(branchIndex: 0, child: _shellPage()),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FuncShellBottomNav(
                    selectedIndex: 0,
                    onSelected: (_) {},
                    scrollVisibility: scrollVisibility,
                    visibleExtent: visibleExtent,
                    indicatorAnimation: const AlwaysStoppedAnimation(0),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  return (container: container, scrollVisibility: scrollVisibility);
}

Widget _messageButtons({required Duration duration}) => Scaffold(
  body: Builder(
    builder: (context) => Column(
      children: [
        TextButton(
          onPressed: () => showAppSnackBar(context, '旧提示', duration: duration),
          child: const Text('show old'),
        ),
        TextButton(
          onPressed: () => showAppSnackBar(context, '最新提示'),
          child: const Text('show latest'),
        ),
        TextButton(
          onPressed: () => showAppSnackBar(
            context,
            '排队旧提示',
            duration: duration,
            replaceCurrent: false,
          ),
          child: const Text('queue stale'),
        ),
        TextButton(
          onPressed: ScaffoldMessenger.of(context).hideCurrentSnackBar,
          child: const Text('dismiss'),
        ),
      ],
    ),
  ),
);

void main() {
  testWidgets('new ordinary snackbar replaces stale queued messages', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_messageButtons(duration: const Duration(seconds: 30))),
    );
    await tester.tap(find.text('show old'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('queue stale'));
    await tester.pump();
    await tester.tap(find.text('show latest'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('旧提示'), findsNothing);
    expect(find.text('最新提示'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.tap(find.text('dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('旧提示'), findsNothing);
    expect(find.text('排队旧提示'), findsNothing);
    expect(find.text('最新提示'), findsNothing);
  });

  testWidgets('the spacer reserves the bar slot on the first frame', (
    tester,
  ) async {
    await _pumpShell(tester);

    // pumpWidget ran exactly one frame — no post-layout measurement has
    // had a chance to publish — and the spacer already matches the
    // rendered bar.
    final barHeight = tester.getSize(find.byType(FuncBottomNav)).height;
    expect(tester.getSize(find.byType(FuncNavBarSpacer)).height, barHeight);

    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('提示内容'), findsOneWidget);

    // The overlay bar owns no bottomNavigationBar slot, so Scaffold
    // geometry cannot lift the SnackBar — the margin grows by the same
    // computed extent the spacer uses. Assert on both the margin and the
    // rendered Material card.
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.margin, EdgeInsets.fromLTRB(16, 0, 16, 16 + barHeight));
    final cardBottom = tester
        .getBottomLeft(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          ),
        )
        .dy;
    expect(
      cardBottom,
      lessThanOrEqualTo(tester.getRect(find.byType(FuncBottomNav)).top),
    );
  });

  testWidgets('the computed extent tracks the navigation inset', (
    tester,
  ) async {
    // Same assertion at three inset depths — no inset, gesture bar and
    // three-button navigation. The first frame is what pumpWidget ran;
    // each re-pump only changes the view padding underneath.
    for (final inset in <double>[0, 24, 48]) {
      tester.view.padding = FakeViewPadding(bottom: inset);
      tester.view.viewPadding = FakeViewPadding(bottom: inset);
      await _pumpShell(tester);
      await tester.pump();
      final expected = FuncBottomNav.restingExtent(inset);
      expect(
        tester.getSize(find.byType(FuncBottomNav)).height,
        expected,
        reason: 'rendered bar height at inset $inset',
      );
      expect(
        tester.getSize(find.byType(FuncNavBarSpacer)).height,
        expected,
        reason: 'spacer height at inset $inset',
      );
    }
  });

  testWidgets('snackbar keeps clearing the shell bar while it slides', (
    tester,
  ) async {
    final shell = await _pumpShell(tester);
    final scrollVisibility = shell.scrollVisibility;
    final extent = tester.getSize(find.byType(FuncBottomNav)).height;

    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    void expectClear() {
      final card = tester.getRect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.byType(Material),
        ),
      );
      final bar = tester.getRect(find.byType(FuncBottomNav));
      expect(
        card.overlaps(bar),
        isFalse,
        reason: 'snackbar must not intersect the shell bar mid-slide',
      );
      // The margin is grown by the resting extent, which never tracks the
      // moving bar — it stays constant through the whole flight.
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).margin,
        EdgeInsets.fromLTRB(16, 0, 16, 16 + extent),
      );
    }

    // Slide out under scroll, then back in — sampled mid-flight both ways.
    final hidden = scrollVisibility.animateTo(
      0,
      duration: MotionTokens.navBarHide,
    );
    while (scrollVisibility.isAnimating) {
      await tester.pump(const Duration(milliseconds: 40));
      expectClear();
    }
    await hidden;
    final shown = scrollVisibility.animateTo(
      1,
      duration: MotionTokens.navBarShow,
    );
    while (scrollVisibility.isAnimating) {
      await tester.pump(const Duration(milliseconds: 40));
      expectClear();
    }
    await shown;
  });

  testWidgets('shared snackbar shape is floating with a uniform margin', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_branchHost(child: _triggerButton()));
    await tester.tap(find.text('show'));
    await tester.pump();

    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.behavior, SnackBarBehavior.floating);
    expect(snackBar.margin, const EdgeInsets.fromLTRB(16, 0, 16, 16));
  });

  testWidgets('action label is rendered and fires its callback', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      _branchHost(
        child: _triggerButton(
          action: SnackBarAction(label: '打开', onPressed: () => tapped = true),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pump();
    // Let the entrance animation finish — during it the SnackBar is
    // wrapped in an AbsorbPointer and the action cannot receive taps.
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('打开'));
    await tester.pump();
    expect(tapped, isTrue);
  });

  testWidgets('reduced motion drops the entrance flight, not the message', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      MotionScope(
        reduce: true,
        child: _branchHost(
          child: _triggerButton(
            action: SnackBarAction(label: '打开', onPressed: () => tapped = true),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    // One frame: AnimationStyle.noAnimation means no entrance flight wraps
    // the card in AbsorbPointer — the action is tappable immediately.
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    final controller =
        tester.widget<SnackBar>(find.byType(SnackBar)).animation!
            as AnimationController;
    expect(controller.duration, Duration.zero);
    expect(controller.reverseDuration, Duration.zero);
    await tester.tap(find.text('打开'));
    expect(tapped, isTrue);
  });

  testWidgets('the shared entrance flight is the mounted animation style', (
    tester,
  ) async {
    await tester.pumpWidget(_branchHost(child: _triggerButton()));
    await tester.tap(find.text('show'));
    await tester.pump();

    // showSnackBar mounts the style onto the entrance controller itself —
    // the SnackBar's `animation` IS that controller. Asserting its
    // durations pins appSnackBarAnimationStyle as the mounted style rather
    // than AnimationStyle.noAnimation or the ~120ms M2 default.
    final controller =
        tester.widget<SnackBar>(find.byType(SnackBar)).animation!
            as AnimationController;
    expect(controller.duration, MotionTokens.medium);
    expect(controller.reverseDuration, MotionTokens.fast);
  });

  testWidgets('wide layout without a bottom bar still shows the snackbar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_branchHost(child: _triggerButton()));
    await tester.pumpAndSettle();
    expect(find.byType(FuncBottomNav), findsNothing);

    await tester.tap(find.text('show'));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('a snackbar with an action times out like any other', (
    tester,
  ) async {
    await tester.pumpWidget(
      _branchHost(
        child: _triggerButton(
          action: SnackBarAction(label: '打开', onPressed: () {}),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pump();
    // pumpAndSettle lands right after the entrance completes — the dwell
    // timer is armed there and schedules no frames, so settle returns
    // without waiting it out.
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);

    // An action no longer pins the message: the dwell timer fires during
    // this elapse and starts the exit flight, which the settle runs to
    // completion — the snackbar leaves the tree.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('提示内容'), findsNothing);
  });

  testWidgets('accessible navigation pins only the action snackbar', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.pumpWidget(
      _branchHost(
        child: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => showAppSnackBar(
                    context,
                    '带按钮提示',
                    action: SnackBarAction(label: '打开', onPressed: () {}),
                  ),
                  child: const Text('show action'),
                ),
                TextButton(
                  onPressed: () => showAppSnackBar(context, '无按钮提示'),
                  child: const Text('show plain'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('show action'));
    await tester.pump();
    await tester.pumpAndSettle();
    // Past the dwell duration the message stays put: with accessible
    // navigation on, an action snackbar keeps its action reachable.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('带按钮提示'), findsOneWidget);

    // A plain message still times out under accessible navigation —
    // the timer fires during the elapse and a11y dismissal is instant.
    await tester.tap(find.text('show plain'));
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('无按钮提示'), findsNothing);
  });
}
