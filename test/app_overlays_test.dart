import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:smooth_sheets/smooth_sheets.dart';

import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/motion/app_overlays.dart';
import 'package:parfait/app/scroll_behavior.dart';
import 'package:parfait/app/widgets/app_dialog.dart';
import 'package:parfait/core/debug/trace_marks.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';

const _page = Size(400, 800);

/// A pushed page (so a double pop would be visible) with two buttons that
/// open the overlay under test.
Future<GlobalKey<NavigatorState>> _pumpPage(
  WidgetTester tester, {
  required Future<void> Function(BuildContext context) open,
  bool disableAnimations = false,
}) async {
  setViewSize(tester, _page);
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

  testWidgets('the panel fade is marked as a scene, in and out', (
    tester,
  ) async {
    final marks = <String>[];
    TraceMarks.sink = marks.add;
    addTearDown(TraceMarks.debugReset);
    final navigatorKey = await _pumpPage(
      tester,
      open: (context) => showAppPanel<void>(
        context: context,
        barrierLabel: 'close',
        builder: (_) => const SizedBox(height: 200, child: Text('overlay')),
      ),
    );
    expect(find.text('overlay'), findsOneWidget);
    expect(
      marks,
      containsAllInOrder(['enter panel', 'event panel in', 'exit panel']),
    );

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('overlay'), findsNothing);
    expect(
      marks,
      containsAllInOrder(['enter panel', 'event panel out', 'exit panel']),
    );
  });

  group('sheet content that fits drags the sheet closed', () {
    // Under the app's bouncing, always-scrollable behaviour the content
    // used to take the drag and rubber-band inside a still panel.
    final contents = <String, Widget>{
      'list': ListView(
        shrinkWrap: true,
        primary: false,
        children: [for (var i = 0; i < 4; i++) ListTile(title: Text('row $i'))],
      ),
      'scroll view': SingleChildScrollView(
        child: Column(
          children: [
            for (var i = 0; i < 4; i++) ListTile(title: Text('row $i')),
          ],
        ),
      ),
    };
    for (final MapEntry(key: kind, value: content) in contents.entries) {
      testWidgets(kind, (tester) async {
        setViewSize(tester, _page);
        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const FuncScrollBehavior(),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAppBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => content,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('row 1'), findsOneWidget);

        await tester.drag(find.text('row 1'), const Offset(0, 300));
        await tester.pumpAndSettle();

        expect(find.text('row 1'), findsNothing);
      });
    }

    testWidgets(
      'useDesktopOverlay respects viewport width and input modality',
      (tester) async {
        late bool decision;
        Future<void> probe(Size size, InputModality modality) async {
          setViewSize(tester, size);
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(size: size),
              child: InputModalityScope(
                key: ValueKey(modality),
                initialModality: modality,
                child: Builder(
                  builder: (context) {
                    decision = useDesktopOverlay(context);
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ),
          );
        }

        await probe(const Size(1024, 768), InputModality.touch);
        expect(decision, isFalse);
        await probe(const Size(599, 800), InputModality.pointer);
        expect(decision, isFalse);
        await probe(const Size(600, 800), InputModality.pointer);
        expect(decision, isTrue);
      },
    );

    testWidgets(
      'useWideOverlay and usePointerOverlay split container shape from pointer anchoring',
      (tester) async {
        late bool wideDecision;
        late bool pointerDecision;
        Future<void> probe(Size size, InputModality modality) async {
          setViewSize(tester, size);
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(size: size),
              child: InputModalityScope(
                key: ValueKey('${size.width}x${size.height}-$modality'),
                initialModality: modality,
                child: Builder(
                  builder: (context) {
                    wideDecision = useWideOverlay(context);
                    pointerDecision = usePointerOverlay(context);
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ),
          );
        }

        await probe(const Size(1024, 768), InputModality.touch);
        expect(wideDecision, isTrue);
        expect(pointerDecision, isFalse);
        await probe(const Size(599, 800), InputModality.pointer);
        expect(wideDecision, isFalse);
        expect(pointerDecision, isFalse);
        await probe(const Size(600, 800), InputModality.pointer);
        expect(wideDecision, isTrue);
        expect(pointerDecision, isTrue);
        await probe(const Size(896, 411), InputModality.touch);
        expect(wideDecision, isFalse);
        expect(pointerDecision, isFalse);
        await probe(const Size(896, 411), InputModality.pointer);
        expect(wideDecision, isFalse);
        expect(pointerDecision, isFalse);
      },
    );

    testWidgets(
      'adaptive dialog, popover, and side sheet adapt on desktop and honor reduced motion',
      (tester) async {
        const wide = Size(1024, 768);
        setViewSize(tester, wide);
        Future<void> pumpHost({bool disableAnimations = false}) =>
            tester.pumpWidget(
              MediaQuery(
                data: MediaQueryData(
                  size: wide,
                  disableAnimations: disableAnimations,
                ),
                child: InputModalityScope(
                  initialModality: InputModality.pointer,
                  child: MaterialApp(
                    home: Scaffold(
                      body: Builder(
                        builder: (context) => Column(
                          children: [
                            TextButton(
                              onPressed: () => showAppAdaptiveDialog<void>(
                                context: context,
                                maxWidth: 440,
                                builder: (_) => const SizedBox(
                                  height: 120,
                                  child: Text('dialog-body'),
                                ),
                              ),
                              child: const Text('open-dialog'),
                            ),
                            TextButton(
                              onPressed: () => showAppAdaptivePopover<void>(
                                context: context,
                                position: const Offset(1015, 760),
                                builder: (_) => const SizedBox(
                                  width: 260,
                                  height: 140,
                                  child: Text('popover-body'),
                                ),
                              ),
                              child: const Text('open-popover'),
                            ),
                            TextButton(
                              onPressed: () => showAppAdaptiveSideSheet<void>(
                                context: context,
                                width: 380,
                                builder: (_) => const SizedBox(
                                  height: 120,
                                  child: Text('side-body'),
                                ),
                              ),
                              child: const Text('open-side'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );

        await pumpHost();
        await tester.tap(
          find.text('open-dialog'),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.byType(AppBottomSheet), findsNothing);
        final dialogRect = tester.getRect(
          find
              .ancestor(
                of: find.text('dialog-body'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(dialogRect.width, lessThanOrEqualTo(440));
        expect(dialogRect.center.dx, closeTo(wide.width / 2, 1));
        await tester.tapAt(const Offset(10, 10), kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();

        await tester.tap(
          find.text('open-popover'),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        final popRect = tester.getRect(
          find
              .ancestor(
                of: find.text('popover-body'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(popRect.right, lessThanOrEqualTo(wide.width));
        expect(popRect.bottom, lessThanOrEqualTo(wide.height));
        await tester.tapAt(const Offset(10, 10), kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(find.text('popover-body'), findsNothing);

        await tester.tap(find.text('open-side'), kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        final sideRect = tester.getRect(
          find
              .ancestor(
                of: find.text('side-body'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(sideRect.width, closeTo(380, 0.1));
        expect(sideRect.right, closeTo(wide.width, 0.1));
        await tester.tapAt(const Offset(10, 10), kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();

        await pumpHost(disableAnimations: true);
        await tester.tap(find.text('open-side'), kind: PointerDeviceKind.mouse);
        await tester.pump();
        expect(find.text('side-body'), findsOneWidget);
      },
    );

    testWidgets(
      'wide touch viewports render bounded dialog, side sheet, and dialog popover',
      (tester) async {
        const tablet = Size(1024, 768);
        setViewSize(tester, tablet);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(size: tablet),
            child: InputModalityScope(
              initialModality: InputModality.touch,
              child: MaterialApp(
                home: Scaffold(
                  body: Builder(
                    builder: (context) => Column(
                      children: [
                        TextButton(
                          onPressed: () => showAppAdaptiveDialog<void>(
                            context: context,
                            maxWidth: 440,
                            builder: (_) => const SizedBox(
                              height: 120,
                              child: Text('touch-dialog'),
                            ),
                          ),
                          child: const Text('open-dialog'),
                        ),
                        TextButton(
                          onPressed: () => showAppAdaptivePopover<void>(
                            context: context,
                            position: const Offset(900, 700),
                            builder: (_) => const SizedBox(
                              height: 120,
                              child: Text('touch-popover'),
                            ),
                          ),
                          child: const Text('open-popover'),
                        ),
                        TextButton(
                          onPressed: () => showAppAdaptiveSideSheet<void>(
                            context: context,
                            width: 380,
                            builder: (_) => const SizedBox(
                              height: 120,
                              child: Text('touch-side'),
                            ),
                          ),
                          child: const Text('open-side'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('open-dialog'));
        await tester.pumpAndSettle();
        expect(find.byType(AppBottomSheet), findsNothing);
        final dialogRect = tester.getRect(
          find
              .ancestor(
                of: find.text('touch-dialog'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(dialogRect.width, lessThanOrEqualTo(440));
        expect(dialogRect.center.dx, closeTo(tablet.width / 2, 1));
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        await tester.tap(find.text('open-popover'));
        await tester.pumpAndSettle();
        expect(find.byType(AppBottomSheet), findsNothing);
        final popDialogRect = tester.getRect(
          find
              .ancestor(
                of: find.text('touch-popover'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(popDialogRect.center.dx, closeTo(tablet.width / 2, 1));
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();

        await tester.tap(find.text('open-side'));
        await tester.pumpAndSettle();
        expect(find.byType(AppBottomSheet), findsNothing);
        final sideRect = tester.getRect(
          find
              .ancestor(
                of: find.text('touch-side'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(sideRect.width, closeTo(380, 0.1));
        expect(sideRect.right, closeTo(tablet.width, 0.1));
      },
    );

    testWidgets(
      'smooth_sheets handles scroll handoff, bounce, reduced motion, 9/16 cap, drag handle and transparent cards',
      (tester) async {
        setViewSize(tester, _page);
        Future<void> pumpSheetHost({
          required Widget child,
          bool isScrollControlled = false,
          bool showDragHandle = false,
          Color? backgroundColor,
          bool disableAnimations = false,
        }) => tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: _page,
              disableAnimations: disableAnimations,
            ),
            child: MaterialApp(
              scrollBehavior: const FuncScrollBehavior(),
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAppBottomSheet<void>(
                    context: context,
                    isScrollControlled: isScrollControlled,
                    showDragHandle: showDragHandle,
                    backgroundColor: backgroundColor,
                    builder: (_) => child,
                  ),
                  child: const Text('open-s4'),
                ),
              ),
            ),
          ),
        );

        // Overflowing scroll -> return to top -> downward drag closes sheet.
        await pumpSheetHost(
          isScrollControlled: false,
          showDragHandle: true,
          child: ListView.builder(
            itemCount: 30,
            itemBuilder: (_, i) => ListTile(title: Text('item $i')),
          ),
        );
        await tester.tap(find.text('open-s4'));
        await tester.pumpAndSettle();
        final sheetRect = tester.getRect(find.byType(AppBottomSheet));
        expect(sheetRect.height, lessThanOrEqualTo(_page.height * 9 / 16 + 1));
        expect(
          tester.widget<Sheet>(find.byType(Sheet)).physics,
          isA<BouncingSheetPhysics>(),
        );
        expect(
          find.descendant(
            of: find.byType(AppBottomSheet),
            matching: find.byWidgetPredicate(
              (w) => w is SizedBox && w.width == 32 && w.height == 4,
            ),
          ),
          findsOneWidget,
        );

        // Upward overdrag settles open; scrolling down and back to top then dragging closes.
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

        // Reduced motion uses ClampingSheetPhysics & zero-duration snap; transparent skips Material.
        await pumpSheetHost(
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          disableAnimations: true,
          child: const SizedBox(height: 160, child: Text('clear-card')),
        );
        await tester.tap(find.text('open-s4'));
        await tester.pump();
        expect(find.text('clear-card'), findsOneWidget);
        expect(
          tester.widget<Sheet>(find.byType(Sheet)).physics,
          isA<ClampingSheetPhysics>(),
        );
        expect(
          tester
              .widget<Material>(
                find.descendant(
                  of: find.byType(AppBottomSheet),
                  matching: find.byType(Material),
                ),
              )
              .type,
          MaterialType.transparency,
        );
      },
    );

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

    testWidgets(
      'adaptive popover scales from anchor direction and re-anchors on resize',
      (tester) async {
        setViewSize(tester, const Size(900, 700));
        final anchorKey = GlobalKey();
        await tester.pumpWidget(
          InputModalityScope(
            initialModality: InputModality.pointer,
            child: MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextButton(
                      key: anchorKey,
                      onPressed: () => showAppAdaptivePopover<void>(
                        context: anchorKey.currentContext!,
                        anchorContext: anchorKey.currentContext,
                        builder: (_) => const SizedBox(
                          width: 200,
                          height: 120,
                          child: Text('anchored-popover'),
                        ),
                      ),
                      child: const Text('anchor'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('anchor'), kind: PointerDeviceKind.mouse);
        await tester.pump();
        final scale = tester.widget<ScaleTransition>(
          find
              .ancestor(
                of: find.text('anchored-popover'),
                matching: find.byType(ScaleTransition),
              )
              .first,
        );
        expect(scale.alignment, Alignment.topRight);
        await tester.pumpAndSettle();

        final before = tester.getRect(find.text('anchored-popover'));
        setViewSize(tester, const Size(1200, 700));
        await tester.pumpAndSettle();
        final after = tester.getRect(find.text('anchored-popover'));
        expect(after.left, greaterThan(before.left + 200));
      },
    );
  });
}
