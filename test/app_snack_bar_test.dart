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

  testWidgets('snackbar inside a branch clears the floating shell bottom bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // The shell bar is an overlay sibling of the branch strip, so the
    // test reproduces that layering: a 64px bar floating at the bottom,
    // and the measured height published exactly like FuncShellBottomNav
    // does on a real shell.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: Stack(
            children: [
              BranchRootScaffold(branchIndex: 0, child: _triggerButton()),
              const Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(key: Key('shellBar'), height: 64),
              ),
            ],
          ),
        ),
      ),
    );
    container.read(homeShellMetricsProvider.notifier).publish(null, 64);
    await tester.pumpAndSettle();

    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('提示内容'), findsOneWidget);

    // The overlay bar owns no bottomNavigationBar slot, so Scaffold
    // geometry cannot lift the SnackBar — showAppSnackBar grows the
    // floating margin by the measured bar height instead. The margin
    // lives inside the SnackBar's own box (Padding around the card), so
    // assert on both the margin and the rendered Material card.
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.margin, const EdgeInsets.fromLTRB(16, 0, 16, 80));
    final cardBottom = tester
        .getBottomLeft(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          ),
        )
        .dy;
    final barTop = tester.getTopLeft(find.byKey(const Key('shellBar'))).dy;
    expect(cardBottom, lessThanOrEqualTo(barTop));
  });

  testWidgets('snackbar follows the visible shell overlap during bar motion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh', 'CN'),
          home: Stack(
            children: [
              BranchRootScaffold(branchIndex: 0, child: _triggerButton()),
              const Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(key: Key('shellBar'), height: 64),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> showAt(double barTop, double expectedOverlap) async {
      container.read(homeShellMetricsProvider.notifier).publish(barTop, 64);
      await tester.tap(find.text('show'));
      await tester.pump();
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).margin,
        EdgeInsets.fromLTRB(16, 0, 16, 16 + expectedOverlap),
      );
      ScaffoldMessenger.of(
        tester.element(find.text('show')),
      ).removeCurrentSnackBar();
      await tester.pumpAndSettle();
    }

    await showAt(780, 64); // fully visible: 844 - 780
    await showAt(812, 32); // halfway through the hide transition
    await showAt(844, 0); // fully slid below the viewport
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
