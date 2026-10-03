import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/widgets/app_menu_button.dart';

const _entries = [
  AppMenuEntry(value: 'share', label: 'Share', icon: Icons.share_outlined),
  AppMenuEntry(value: 'off', label: 'Unavailable', enabled: false),
  AppMenuEntry(value: 'public', label: 'Public', checked: true),
  AppMenuEntry(value: 'private', label: 'Private', checked: false),
];

class _Harness extends StatelessWidget {
  const _Harness({
    required this.onSelected,
    this.onBelowTap,
    this.scrollController,
    this.entries = _entries,
  });

  final void Function(BuildContext, String) onSelected;
  final VoidCallback? onBelowTap;
  final ScrollController? scrollController;
  final List<AppMenuEntry<String>> entries;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          AppMenuButton<String>(entries: entries, onSelected: onSelected),
        ],
      ),
      body: ListView(
        controller: scrollController,
        children: [
          SizedBox(
            height: 200,
            child: Center(
              child: TextButton(
                onPressed: onBelowTap,
                child: const Text('below'),
              ),
            ),
          ),
          for (var i = 0; i < 30; i++)
            SizedBox(height: 80, child: Text('row $i')),
        ],
      ),
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  bool disableAnimations = false,
  Size size = const Size(400, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size, disableAnimations: disableAnimations),
      child: MaterialApp(home: home),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
  expect(find.text('Share'), findsOneWidget);
}

void main() {
  testWidgets('a pointer going down outside closes the menu at once', (
    tester,
  ) async {
    await _pump(tester, _Harness(onSelected: (_, _) {}));
    await _open(tester);

    final gesture = await tester.startGesture(const Offset(200, 600));
    await tester.pumpAndSettle();
    expect(find.text('Share'), findsNothing);
    await gesture.up();
  });

  testWidgets('the closing touch never scrolls the page below', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _pump(
      tester,
      _Harness(onSelected: (_, _) {}, scrollController: controller),
    );
    await _open(tester);

    await tester.dragFrom(const Offset(200, 600), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.text('Share'), findsNothing);
    expect(controller.offset, 0);
  });

  testWidgets('the closing touch never taps the control below', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      _Harness(onSelected: (_, _) {}, onBelowTap: () => taps++),
    );
    await _open(tester);

    await tester.tap(find.text('below'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Share'), findsNothing);
    expect(taps, 0);
    // With the menu closed the control works again.
    await tester.tap(find.text('below'));
    expect(taps, 1);
  });

  testWidgets('the anchor toggles the menu closed again', (tester) async {
    await _pump(tester, _Harness(onSelected: (_, _) {}));
    await _open(tester);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Share'), findsNothing);
  });

  testWidgets('back closes the menu before the page', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('root')),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => _Harness(onSelected: (_, _) {})),
    );
    await tester.pumpAndSettle();
    await _open(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Share'), findsNothing);
    expect(find.byType(_Harness), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(_Harness), findsNothing);
    expect(find.text('root'), findsOneWidget);
  });

  testWidgets('a page leaving with the menu open tears down cleanly', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('root')),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => _Harness(onSelected: (_, _) {})),
    );
    await tester.pumpAndSettle();
    await _open(tester);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Share'), findsNothing);
    expect(find.text('root'), findsOneWidget);
  });

  testWidgets('selection reports the anchor context and closes the menu', (
    tester,
  ) async {
    BuildContext? anchor;
    String? selected;
    await _pump(
      tester,
      _Harness(
        onSelected: (context, value) {
          anchor = context;
          selected = value;
        },
      ),
    );
    await _open(tester);

    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(selected, 'share');
    expect(find.text('Share'), findsNothing);
    // The context sits at the button, not at the menu or the page.
    final box = anchor!.findRenderObject()! as RenderBox;
    final buttonCenter = tester.getCenter(find.byIcon(Icons.more_vert));
    expect(
      (box.localToGlobal(Offset.zero) & box.size).contains(buttonCenter),
      isTrue,
    );
  });

  testWidgets('disabled rows do nothing; checkable rows report checked', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final picks = <String>[];
    await _pump(tester, _Harness(onSelected: (_, value) => picks.add(value)));
    await _open(tester);

    await tester.tap(find.text('Unavailable'), warnIfMissed: false);
    await tester.pump();
    expect(picks, isEmpty);

    expect(
      tester.getSemantics(find.text('Public')),
      isSemantics(
        label: 'Public',
        hasCheckedState: true,
        isChecked: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.text('Unavailable')),
      isSemantics(hasEnabledState: true, isEnabled: false),
    );
    expect(
      tester.getSemantics(find.text('Private')),
      isSemantics(hasCheckedState: true, isChecked: false),
    );
    expect(
      tester.getSemantics(find.text('Share')),
      isSemantics(hasTapAction: true, hasCheckedState: false),
    );
    // Only the checked row shows the trailing check.
    expect(find.byIcon(Icons.check), findsOneWidget);
    handle.dispose();
  });

  testWidgets('reduced motion opens the menu without an animation', (
    tester,
  ) async {
    await _pump(
      tester,
      _Harness(onSelected: (_, _) {}),
      disableAnimations: true,
    );
    expect(tester.widget<MenuAnchor>(find.byType(MenuAnchor)).animated, false);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    expect(find.text('Share'), findsOneWidget);
  });

  testWidgets('long labels truncate inside the width cap on a narrow phone', (
    tester,
  ) async {
    const long =
        'Перейти к сведениям о работе и посмотреть все теги и описание';
    await _pump(
      tester,
      _Harness(
        onSelected: (_, _) {},
        entries: const [
          AppMenuEntry(value: 'a', label: long, icon: Icons.info_outline),
          AppMenuEntry(value: 'b', label: long, checked: true),
        ],
      ),
      size: const Size(320, 640),
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final item in find.byType(MenuItemButton).evaluate()) {
      expect(
        tester.getSize(find.byWidget(item.widget)).width,
        lessThanOrEqualTo(kAppMenuMaxWidth),
      );
    }
  });
}
