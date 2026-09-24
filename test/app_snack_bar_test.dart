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

void main() {
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
    await tester.tap(find.text('打开'));
    expect(tapped, isTrue);
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
}
