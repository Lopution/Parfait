import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/entity_row.dart';

import 'support/contrast.dart';

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
          badge: EntityBadge(label: '7'),
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

  testWidgets('long title and subtitle stay inside the row at 1.3x text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: _host(
          const SizedBox(
            width: 320,
            child: EntityRow(
              leading: SizedBox(width: 48, height: 48),
              title: '一个很长很长很长很长的作品标题',
              subtitle: '一个很长很长的作者名字',
              meta: '12345 字',
              trailing: Icon(Icons.more_vert),
            ),
          ),
        ),
      ),
    );

    // Overflow throws inside RenderFlex during the pump above.
    expect(tester.takeException(), isNull);
    expect(find.text('12345 字'), findsOneWidget);
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
    expect(material.color, scheme.primaryContainer);
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

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('selected row text keeps 4.5:1 contrast ($brightness)', (
      tester,
    ) async {
      final theme = replicaTheme(brightness);
      final scheme = theme.colorScheme;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: EntityRow(
              leading: SizedBox(width: 48),
              title: 'Pick me',
              subtitle: 'An author',
              meta: '1234 words',
              selected: true,
            ),
          ),
        ),
      );

      final background = scheme.primaryContainer;
      final secondary = scheme.onPrimaryContainer.withValues(alpha: 0.8);
      for (final label in ['An author', '1234 words']) {
        final style = tester.widget<Text>(find.text(label)).style!;
        // The alpha-carrying color composites onto the row surface before
        // the contrast is measured.
        expect(
          contrastRatio(Color.alphaBlend(style.color!, background), background),
          greaterThanOrEqualTo(4.5),
          reason: '$brightness "$label" contrast',
        );
        expect(style.color, secondary, reason: '$brightness "$label" color');
      }
      final titleStyle = tester.widget<Text>(find.text('Pick me')).style!;
      expect(
        contrastRatio(titleStyle.color!, background),
        greaterThanOrEqualTo(4.5),
        reason: '$brightness title contrast',
      );
      expect(titleStyle.color, scheme.onPrimaryContainer);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.check_circle)).color,
        scheme.onPrimaryContainer,
      );
    });
  }
}
