import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pixiv_func/app/widgets/entity_row.dart';

Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  testWidgets('renders every populated slot', (tester) async {
    await tester.pumpWidget(
      _host(
        const EntityRow(
          leading: SizedBox(width: 48, height: 48),
          title: 'A title',
          subtitle: 'An author',
          meta: '1234 words',
          badge: EntityBadge(child: Text('7')),
          trailing: Icon(Icons.more_vert),
        ),
      ),
    );

    expect(find.text('A title'), findsOneWidget);
    expect(find.text('An author'), findsOneWidget);
    expect(find.text('1234 words'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
  });

  testWidgets('empty slots render nothing extra', (tester) async {
    await tester.pumpWidget(
      _host(const EntityRow(leading: SizedBox(width: 48), title: 'Bare title')),
    );
    expect(find.text('Bare title'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('selected paints the row and appends a check', (tester) async {
    await tester.pumpWidget(
      _host(
        const EntityRow(
          leading: SizedBox(width: 48),
          title: 'Pick me',
          selected: true,
        ),
      ),
    );
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    final material = tester.widget<Material>(
      find.descendant(
        of: find.byType(EntityRow),
        matching: find.byType(Material),
      ),
    );
    final scheme = Theme.of(tester.element(find.byType(EntityRow))).colorScheme;
    expect(material.color, scheme.secondaryContainer);
  });

  testWidgets('tap and long-press reach the row', (tester) async {
    var taps = 0;
    var longPresses = 0;
    await tester.pumpWidget(
      _host(
        EntityRow(
          leading: const SizedBox(width: 48),
          title: 'Pressable',
          onTap: () => taps++,
          onLongPress: () => longPresses++,
        ),
      ),
    );
    await tester.tap(find.text('Pressable'));
    await tester.longPress(find.text('Pressable'));
    expect(taps, 1);
    expect(longPresses, 1);
  });

  testWidgets('progress slot honors the null vs zero boundary', (tester) async {
    // null = no record → no bar at all; 0.0 = a real record at the start.
    await tester.pumpWidget(
      _host(
        const EntityRow(leading: SizedBox(width: 48), title: 'No progress'),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.pumpWidget(
      _host(
        const EntityRow(
          leading: SizedBox(width: 48),
          title: 'At the start',
          progress: 0,
        ),
      ),
    );
    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, 0);
  });

  testWidgets('semantic label defaults to title plus subtitle', (tester) async {
    await tester.pumpWidget(
      _host(
        EntityRow(
          leading: const SizedBox(width: 48),
          title: 'Named work',
          subtitle: 'Its author',
          onTap: () {},
        ),
      ),
    );
    expect(find.bySemanticsLabel('Named work, Its author'), findsOneWidget);
  });

  testWidgets('explicit semantic label wins over the default', (tester) async {
    await tester.pumpWidget(
      _host(
        const EntityRow(
          leading: SizedBox(width: 48),
          title: 'Named work',
          subtitle: 'Its author',
          semanticLabel: 'Custom label',
        ),
      ),
    );
    expect(find.bySemanticsLabel('Custom label'), findsOneWidget);
  });
}
