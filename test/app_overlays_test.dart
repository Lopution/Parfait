import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/motion/app_overlays.dart';

const _page = Size(400, 800);

/// A pushed page (so a double pop would be visible) with two buttons that
/// open the overlay under test.
Future<GlobalKey<NavigatorState>> _pumpPage(
  WidgetTester tester, {
  required Future<void> Function(BuildContext context) open,
  bool disableAnimations = false,
}) async {
  tester.view.physicalSize = _page;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: _page, disableAnimations: disableAnimations),
      child: MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('root')),
      ),
    ),
  );
  navigatorKey.currentState!.push(
    MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: TextButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return navigatorKey;
}

Future<void> _openDialog(BuildContext context, {bool dismissible = true}) =>
    showAppDialog<void>(
      context: context,
      barrierDismissible: dismissible,
      builder: (_) => const AlertDialog(content: Text('overlay')),
    );

Future<void> _openSheet(BuildContext context) => showAppBottomSheet<void>(
  context: context,
  builder: (_) => const SizedBox(height: 200, child: Text('overlay')),
);

void main() {
  for (final (kind, open) in [
    ('dialog', (BuildContext c) => _openDialog(c)),
    ('sheet', _openSheet),
  ]) {
    group(kind, () {
      testWidgets('a drag outside closes it on release, one layer only', (
        tester,
      ) async {
        await _pumpPage(tester, open: open);
        expect(find.text('overlay'), findsOneWidget);

        // Starts and ends on the scrim, well above the overlay.
        final gesture = await tester.startGesture(const Offset(200, 120));
        await gesture.moveBy(const Offset(0, 100));
        await tester.pump();
        expect(find.text('overlay'), findsOneWidget, reason: 'not yet');
        await gesture.up();
        await tester.pumpAndSettle();

        expect(find.text('overlay'), findsNothing);
        expect(find.text('open'), findsOneWidget);
        expect(find.text('root'), findsNothing);
      });

      testWidgets('a tap outside closes one layer', (tester) async {
        await _pumpPage(tester, open: open);
        await tester.tapAt(const Offset(200, 120));
        await tester.pumpAndSettle();
        expect(find.text('overlay'), findsNothing);
        expect(find.text('open'), findsOneWidget);
      });

      testWidgets('a drag that ends over the content keeps it open', (
        tester,
      ) async {
        await _pumpPage(tester, open: open);
        final target = tester.getCenter(find.text('overlay'));
        final gesture = await tester.startGesture(const Offset(200, 120));
        await gesture.moveTo(target);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.text('overlay'), findsOneWidget);
      });

      testWidgets('the scrim offers a dismiss action to assistive tech', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await _pumpPage(tester, open: open);
        final scrim = tester.semantics.find(
          find.byWidgetPredicate((w) => w is BlockSemantics).last,
        );
        expect(scrim, isSemantics(hasDismissAction: true, hasTapAction: true));
        tester.semantics.performAction(
          find.semantics.byAction(SemanticsAction.dismiss),
          SemanticsAction.dismiss,
        );
        await tester.pumpAndSettle();
        expect(find.text('overlay'), findsNothing);
        expect(find.text('open'), findsOneWidget);
        handle.dispose();
      });
    });
  }

  testWidgets('a dialog that is not barrier-dismissible stays open', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      open: (context) => _openDialog(context, dismissible: false),
    );
    await tester.tapAt(const Offset(200, 120));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(200, 120), const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(find.text('overlay'), findsOneWidget);
  });

  testWidgets('the page below never sees a touch on the scrim', (tester) async {
    var taps = 0;
    await _pumpPage(
      tester,
      open: (context) {
        taps++;
        return _openDialog(context, dismissible: false);
      },
    );
    expect(taps, 1);
    await tester.tap(find.text('open'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('reduced motion still shows both at once', (tester) async {
    for (final open in [(BuildContext c) => _openDialog(c), _openSheet]) {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: _page, disableAnimations: true),
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(find.text('overlay'), findsOneWidget);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
    }
  });
}
