import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/widgets/entity_row.dart';

Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
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
}
