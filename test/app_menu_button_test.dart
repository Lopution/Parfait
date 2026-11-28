import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/icons/ui_icons.dart';
import 'package:parfait/app/widgets/app_menu_button.dart';

import 'helpers/view_size.dart';

const _entries = [
  AppMenuEntry(value: 'share', label: 'Share'),
  AppMenuEntry(value: 'save', label: 'Save'),
];

class _Harness extends StatelessWidget {
  const _Harness({
    required this.onSelected,
    this.onBelowTap,
    this.scrollController,
  });

  final void Function(BuildContext, String) onSelected;
  final VoidCallback? onBelowTap;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          AppMenuButton<String>(entries: _entries, onSelected: onSelected),
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
  Size size = const Size(400, 800),
}) async {
  setViewSize(tester, size);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(home: home),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byIcon(UiIcons.more));
  await tester.pumpAndSettle();
  expect(find.text('Share'), findsOneWidget);
}

void main() {
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

  testWidgets('back closes the menu before the page', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    setViewSize(tester, const Size(400, 800));
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
}
