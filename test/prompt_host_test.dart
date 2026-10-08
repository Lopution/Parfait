import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/motion/app_overlays.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/navigation/home_shell_metrics.dart';
import 'package:parfait/app/touch_exploration_scope.dart';
import 'package:parfait/app/widgets/app_snack_bar.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'package:parfait/app/widgets/prompt_anchor.dart';
import 'package:parfait/app/widgets/prompt_host.dart';
import 'package:parfait/core/platform/accessibility.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/prompt_host.dart';

const _screen = Size(390, 844);

/// The platform timeout channel is the external boundary: this double
/// answers like `getRecommendedTimeoutMillis` with a scaled timeout and
/// records what it was asked.
class _ScaledTimeouts implements AppAccessibility {
  _ScaledTimeouts(this.factor);

  final int factor;
  final requests = <(int, int)>[];

  @override
  Future<bool> isTouchExplorationEnabled() async => false;

  @override
  Stream<bool> touchExplorationChanges() => const Stream.empty();

  @override
  Future<int> recommendedTimeoutMillis(int baseMs, int contentFlags) async {
    requests.add((baseMs, contentFlags));
    return baseMs * factor;
  }
}

void _useScreen(WidgetTester tester, [Size size = _screen]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _app({
  required Widget home,
  TransitionBuilder builder = promptHostBuilder,
  List<Override> overrides = const [],
  bool reduceMotion = false,
}) {
  Widget app = MaterialApp(
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh', 'CN'),
    builder: builder,
    home: home,
  );
  if (reduceMotion) app = MotionScope(reduce: true, child: app);
  return ProviderScope(overrides: overrides, child: app);
}

/// A page of labelled buttons, each running its callback with a context
/// below the host.
class _Buttons extends StatelessWidget {
  const _Buttons(this.buttons, {this.bottom});

  final Map<String, void Function(BuildContext context)> buttons;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const SizedBox(height: 80),
        for (final MapEntry(:key, :value) in buttons.entries)
          Builder(
            builder: (context) =>
                TextButton(onPressed: () => value(context), child: Text(key)),
          ),
        const Spacer(),
        ?bottom,
      ],
    ),
  );
}

/// What the user sees of the prompt: every fade between it and the host
/// multiplied — the entrance flight and the modal cover.
double _opacity(WidgetTester tester, String message) {
  var opacity = 1.0;
  for (final fade in tester.widgetList<FadeTransition>(
    find.ancestor(
      of: promptCard(message),
      matching: find.byType(FadeTransition),
    ),
  )) {
    opacity *= fade.opacity.value;
  }
  return opacity;
}

void main() {
  group('queue', () {
    testWidgets('a new prompt replaces the current one and drops the queue', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          home: _Buttons({
            'old': (c) => showAppSnackBar(
              c,
              '旧提示',
              duration: const Duration(seconds: 30),
            ),
            'queue': (c) => showAppSnackBar(c, '排队提示', replaceCurrent: false),
            'latest': (c) => showAppSnackBar(c, '最新提示'),
          }),
        ),
      );
      await tester.tap(find.text('old'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('queue'));
      await tester.pump();
      // Queued behind the one on screen, not shown over it.
      expect(find.text('旧提示'), findsOneWidget);
      expect(find.text('排队提示'), findsNothing);

      await tester.tap(find.text('latest'));
      await tester.pumpAndSettle();
      expect(find.text('旧提示'), findsNothing);
      expect(find.text('排队提示'), findsNothing);
      expect(find.text('最新提示'), findsOneWidget);
    });

    testWidgets('ordered prompts show one after another', (tester) async {
      await tester.pumpWidget(
        _app(
          home: _Buttons({
            'first': (c) => showAppSnackBar(c, '第一步'),
            'second': (c) => showAppSnackBar(c, '第二步', replaceCurrent: false),
          }),
        ),
      );
      await tester.tap(find.text('first'));
      await tester.tap(find.text('second'));
      await tester.pumpAndSettle();
      expect(find.text('第一步'), findsOneWidget);
      expect(find.text('第二步'), findsNothing);

      await tester.pump(defaultPromptDuration);
      await tester.pumpAndSettle();
      expect(find.text('第一步'), findsNothing);
      expect(find.text('第二步'), findsOneWidget);
    });

    testWidgets('swiping down dismisses and the next prompt follows', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          home: _Buttons({
            'first': (c) => showAppSnackBar(c, '第一步'),
            'second': (c) => showAppSnackBar(c, '第二步', replaceCurrent: false),
          }),
        ),
      );
      await tester.tap(find.text('first'));
      await tester.tap(find.text('second'));
      await tester.pumpAndSettle();

      await tester.drag(find.text('第一步'), const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(find.text('第一步'), findsNothing);
      expect(find.text('第二步'), findsOneWidget);
    });
  });

  group('dwell', () {
    testWidgets('a prompt with an action times out like any other', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          home: _Buttons({
            'show': (c) => showAppSnackBar(
              c,
              '带按钮提示',
              action: PromptAction(label: '打开', onPressed: () {}),
            ),
          }),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(find.text('带按钮提示'), findsOneWidget);

      await tester.pump(defaultPromptDuration);
      await tester.pumpAndSettle();
      expect(find.text('带按钮提示'), findsNothing);
    });

    testWidgets('the system timeout stretches the dwell', (tester) async {
      final timeouts = _ScaledTimeouts(3);
      await tester.pumpWidget(
        _app(
          builder: (context, child) =>
              PromptHost(accessibility: timeouts, child: child!),
          home: _Buttons({
            'plain': (c) => showAppSnackBar(c, '纯文字'),
            'action': (c) => showAppSnackBar(
              c,
              '带按钮',
              action: PromptAction(label: '打开', onPressed: () {}),
            ),
          }),
        ),
      );
      await tester.tap(find.text('plain'));
      await tester.pumpAndSettle();
      // Past the 4s base, inside the 12s the system asked for.
      await tester.pump(const Duration(seconds: 8));
      expect(find.text('纯文字'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('纯文字'), findsNothing);

      await tester.tap(find.text('action'));
      await tester.pumpAndSettle();
      expect(timeouts.requests, [
        (4000, AppAccessibility.contentText),
        (4000, AppAccessibility.contentText | AppAccessibility.contentControls),
      ]);
    });

    testWidgets('touch exploration pins only the action prompt', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(
        _app(
          home: _Buttons({
            'action': (c) => showAppSnackBar(
              c,
              '带按钮提示',
              action: PromptAction(label: '打开', onPressed: () {}),
            ),
            'plain': (c) => showAppSnackBar(c, '无按钮提示'),
          }),
        ),
      );
      await tester.tap(find.text('action'));
      await tester.pump();
      // No flight under TalkBack: fully in on the first frame.
      expect(_opacity(tester, '带按钮提示'), 1);
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('带按钮提示'), findsOneWidget);

      await tester.tap(find.text('plain'));
      await tester.pump();
      await tester.pump(defaultPromptDuration);
      await tester.pump();
      expect(find.text('无按钮提示'), findsNothing);
    });

    testWidgets('a polluted engine flag neither pins nor stills prompts', (
      tester,
    ) async {
      // The user's device: GKD sets the engine's accessibleNavigation, but
      // TalkBack is off. Below TouchExplorationScope the host sees the
      // real flag.
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(
        _app(
          overrides: [
            touchExplorationProvider.overrideWith((ref) => Stream.value(false)),
          ],
          builder: (context, child) =>
              TouchExplorationScope(child: promptHostBuilder(context, child)),
          home: _Buttons({
            'show': (c) => showAppSnackBar(
              c,
              '带按钮提示',
              action: PromptAction(label: '打开', onPressed: () {}),
            ),
          }),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('show'));
      await tester.pump();
      expect(_opacity(tester, '带按钮提示'), 0);
      await tester.pumpAndSettle();
      expect(_opacity(tester, '带按钮提示'), 1);

      await tester.pump(defaultPromptDuration);
      await tester.pumpAndSettle();
      expect(find.text('带按钮提示'), findsNothing);
    });
  });

  group('motion', () {
    testWidgets('reduced motion drops the flight, not the message', (
      tester,
    ) async {
      var tapped = false;
      await tester.pumpWidget(
        _app(
          reduceMotion: true,
          home: _Buttons({
            'show': (c) => showAppSnackBar(
              c,
              '提示',
              action: PromptAction(label: '打开', onPressed: () => tapped = true),
            ),
          }),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pump();
      expect(_opacity(tester, '提示'), 1);
      await tester.tap(promptAction('打开'));
      expect(tapped, isTrue);
    });
  });

  group('interaction', () {
    testWidgets('the action fires once and hides the prompt', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          home: _Buttons({
            'show': (c) => showAppSnackBar(
              c,
              '提示',
              action: PromptAction(label: '打开', onPressed: () => taps++),
            ),
          }),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      await tester.tap(promptAction('打开'));
      await tester.pump();
      await tester.tap(promptAction('打开'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(find.text('提示'), findsNothing);
    });

    testWidgets('announces as a live region and dismisses from semantics', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          home: _Buttons({
            'show': (c) =>
                showAppSnackBar(c, '提示', duration: const Duration(seconds: 30)),
          }),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.text('提示')),
        isSemantics(label: '提示', isLiveRegion: true, hasDismissAction: true),
      );

      tester.semantics.performAction(
        find.semantics.byLabel('提示'),
        SemanticsAction.dismiss,
      );
      await tester.pumpAndSettle();
      expect(find.text('提示'), findsNothing);
      handle.dispose();
    });

    testWidgets('a sheet or dialog covers the prompt and takes its taps', (
      tester,
    ) async {
      var tapped = false;
      await tester.pumpWidget(
        _app(
          home: _Buttons({
            'show': (c) => showAppSnackBar(
              c,
              '提示',
              duration: const Duration(seconds: 30),
              action: PromptAction(label: '打开', onPressed: () => tapped = true),
            ),
            'sheet': (c) => unawaited(
              showAppBottomSheet<void>(
                context: c,
                builder: (_) => const SizedBox(height: 120),
              ),
            ),
            'dialog': (c) => unawaited(
              showAppDialog<void>(
                context: c,
                builder: (_) => const AlertDialog(content: Text('对话框')),
              ),
            ),
          }),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      final action = tester.getCenter(promptAction('打开'));

      for (final modal in ['sheet', 'dialog']) {
        await tester.tap(find.text(modal));
        await tester.pumpAndSettle();
        expect(_opacity(tester, '提示'), 0, reason: modal);
        // The prompt still sits above in paint order but lets the tap
        // through to the modal surface, whose scrim closes it.
        await tester.tapAt(action);
        await tester.pumpAndSettle();
        expect(tapped, isFalse, reason: modal);
        expect(_opacity(tester, '提示'), 1, reason: modal);
      }
    });
  });

  group('placement', () {
    testWidgets('makes room for the keyboard', (tester) async {
      _useScreen(tester);
      await tester.pumpWidget(
        _app(home: _Buttons({'show': (c) => showAppSnackBar(c, '提示')})),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(
        tester.getRect(promptCard('提示')).bottom,
        _screen.height - 300 - 16,
      );
    });

    testWidgets('an anchor sinks while a page covers its route', (
      tester,
    ) async {
      _useScreen(tester);
      final extent = ValueNotifier<double>(80);
      addTearDown(extent.dispose);
      await tester.pumpWidget(
        _app(
          home: _Buttons(
            {
              'show': (c) => showAppSnackBar(
                c,
                '提示',
                duration: const Duration(seconds: 30),
              ),
              'push': (c) => unawaited(
                Navigator.of(c).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('二级页')),
                  ),
                ),
              ),
            },
            bottom: PromptAnchor(
              extent: extent,
              child: const SizedBox(height: 80),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      final above = tester.getRect(promptCard('提示')).bottom;

      await tester.tap(find.text('push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final midway = tester.getRect(promptCard('提示')).bottom;
      expect(midway, greaterThan(above));
      expect(midway, lessThan(_screen.height - 16));
      await tester.pumpAndSettle();
      expect(tester.getRect(promptCard('提示')).bottom, _screen.height - 16);

      Navigator.of(tester.element(find.text('二级页'))).pop();
      await tester.pumpAndSettle();
      expect(tester.getRect(promptCard('提示')).bottom, above);
    });
  });

  group('shell bar', () {
    /// Mounts the real shell bar as an overlay sibling of the branch strip —
    /// the same layering the home shell uses, with [HomeShellChrome]
    /// computed the way [HomeBranchStack] computes it.
    Future<AnimationController> pumpShell(WidgetTester tester) async {
      _useScreen(tester);
      final scrollVisibility = AnimationController(vsync: tester, value: 1);
      addTearDown(scrollVisibility.dispose);
      final visibleExtent = ValueNotifier<double>(0);
      addTearDown(visibleExtent.dispose);
      await tester.pumpWidget(
        _app(
          home: Builder(
            builder: (context) => HomeShellChrome(
              bottomBarExtent: FuncBottomNav.restingExtent(
                MediaQuery.paddingOf(context).bottom,
              ),
              bottomBarVisibleExtent: visibleExtent,
              bottomBarVisibility: scrollVisibility,
              onBranchRootScroll: (_) => false,
              child: Stack(
                children: [
                  BranchRootScaffold(
                    branchIndex: 0,
                    child: _Buttons({
                      'show': (c) => showAppSnackBar(c, '提示'),
                    }, bottom: const FuncNavBarSpacer()),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: FuncShellBottomNav(
                      selectedIndex: 0,
                      onSelected: (_) {},
                      scrollVisibility: scrollVisibility,
                      visibleExtent: visibleExtent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      return scrollVisibility;
    }

    testWidgets('the prompt rides the bar as it slides', (tester) async {
      final scrollVisibility = await pumpShell(tester);
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();

      void expectAboveBar() {
        final card = tester.getRect(promptCard('提示'));
        final bar = tester.getRect(find.byType(FuncBottomNav));
        final barTop = bar.top.clamp(0, _screen.height);
        expect(card.bottom, closeTo(barTop - 16, 0.5));
      }

      expectAboveBar();
      // Slide out under scroll, then back in — sampled mid-flight both ways.
      final hidden = scrollVisibility.animateTo(
        0,
        duration: MotionTokens.chromeScrollHide,
      );
      while (scrollVisibility.isAnimating) {
        await tester.pump(const Duration(milliseconds: 40));
        expectAboveBar();
      }
      await hidden;
      expect(tester.getRect(promptCard('提示')).bottom, _screen.height - 16);
      final shown = scrollVisibility.animateTo(
        1,
        duration: MotionTokens.chromeScrollHide,
      );
      while (scrollVisibility.isAnimating) {
        await tester.pump(const Duration(milliseconds: 40));
        expectAboveBar();
      }
      await shown;
    });

    testWidgets('a branch-root prompt belongs to the host, not the page', (
      tester,
    ) async {
      await pumpShell(tester);
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      // No per-branch messenger: the prompt sits above every navigator, so
      // it outlives the page and never hides under the shell bar.
      expect(
        find.descendant(
          of: find.byType(BranchRootScaffold),
          matching: find.byType(ScaffoldMessenger),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.text('提示'),
          matching: find.byType(BranchRootScaffold),
        ),
        findsNothing,
      );
    });
  });
}
