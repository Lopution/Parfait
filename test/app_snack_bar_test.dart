import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

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
  testWidgets(
    'snackbar inside a branch lands above the bottom navigation bar',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_branchHost(child: _triggerButton()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('show'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('提示内容'), findsOneWidget);

      // The messenger lives inside the branch Scaffold's body, so a
      // floating SnackBar anchors to the body edge — never covering the
      // bottom bar. Before this, callers resolved the root messenger whose
      // region spans the whole screen and painted over the bar.
      final snackBarBottom = tester.getBottomLeft(find.byType(SnackBar)).dy;
      final navTop = tester.getTopLeft(find.byType(FuncBottomNav)).dy;
      expect(snackBarBottom, lessThanOrEqualTo(navTop));
    },
  );

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
