import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/motion/app_overlays.dart';
import 'package:parfait/app/scroll_behavior.dart';
import 'package:parfait/app/widgets/app_dialog.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';

const _page = Size(400, 800);

Future<GlobalKey<NavigatorState>> _pumpPage(
  WidgetTester tester, {
  required Future<void> Function(BuildContext context) open,
}) async {
  setViewSize(tester, _page);
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: _page),
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

  testWidgets(
    'AppDatePickerDialog clamps out-of-range today and returns a local DateTime',
    (tester) async {
      DateTime? picked;
      late String okLabel;
      await tester.pumpWidget(
        localizedApp(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                okLabel = MaterialLocalizations.of(context).okButtonLabel;
                picked = await showAppDatePicker(
                  context: context,
                  firstDate: DateTime(2007, 9, 13),
                  lastDate: DateTime(2007, 9, 20),
                  initialDate: DateTime(2007, 9, 18),
                );
              },
              child: const Text('Pick'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      expect(find.byType(FCalendar), findsOneWidget);

      await tester.tap(find.text(okLabel));
      await tester.pumpAndSettle();
      expect(picked, DateTime(2007, 9, 18));
      expect(picked!.isUtc, isFalse);
    },
  );

  testWidgets(
    'AppAlertDialog mounts FDialog with inner Material for TextField',
    (tester) async {
      await tester.pumpWidget(
        localizedApp(
          body: AppAlertDialog(
            title: const Text('Title'),
            content: const TextField(),
            actions: [TextButton(onPressed: () {}, child: const Text('OK'))],
          ),
        ),
      );

      expect(find.byType(FDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(FDialog),
          matching: find.byType(Material),
        ),
        findsWidgets,
      );
    },
  );

  testWidgets('smooth_sheets handles scroll handoff and reduced motion', (
    tester,
  ) async {
    setViewSize(tester, _page);
    Future<void> pumpSheetHost({
      required Widget child,
      bool isScrollControlled = false,
      bool disableAnimations = false,
    }) => tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: _page, disableAnimations: disableAnimations),
        child: MaterialApp(
          scrollBehavior: const FuncScrollBehavior(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppBottomSheet<void>(
                context: context,
                isScrollControlled: isScrollControlled,
                builder: (_) => child,
              ),
              child: const Text('open-sheet'),
            ),
          ),
        ),
      ),
    );

    // Scroll down, return to top, then drag downward to close the sheet.
    await pumpSheetHost(
      child: ListView.builder(
        itemCount: 30,
        itemBuilder: (_, i) => ListTile(title: Text('item $i')),
      ),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    await tester.drag(find.text('item 1'), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(find.byType(AppBottomSheet), findsOneWidget);
    await tester.drag(find.text('item 4'), const Offset(0, 600));
    await tester.pumpAndSettle();
    if (find.byType(AppBottomSheet).evaluate().isNotEmpty) {
      await tester.drag(find.text('item 1'), const Offset(0, 350));
      await tester.pumpAndSettle();
    }
    expect(find.byType(AppBottomSheet), findsNothing);

    // Reduced motion uses ClampingSheetPhysics & opens immediately.
    await pumpSheetHost(
      isScrollControlled: true,
      disableAnimations: true,
      child: const SizedBox(height: 160, child: Text('reduced-sheet')),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pump();
    expect(find.text('reduced-sheet'), findsOneWidget);
    expect(
      tester.widget<Sheet>(find.byType(Sheet)).physics,
      isA<ClampingSheetPhysics>(),
    );
  });
}
