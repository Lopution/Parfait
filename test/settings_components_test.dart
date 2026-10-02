import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/settings/settings_action_tile.dart';
import 'package:parfait/app/widgets/settings/settings_choice_tile.dart';
import 'package:parfait/app/widgets/settings/settings_control.dart';
import 'package:parfait/app/widgets/settings/settings_group.dart';
import 'package:parfait/app/widgets/settings/settings_group_content.dart';
import 'package:parfait/app/widgets/settings/settings_tile.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: replicaTheme(Brightness.light),
    home: Scaffold(body: child),
  );
}

void _noop() {}
void _ignoreBool(bool _) {}

void main() {
  testWidgets('every settings row type renders inside a group', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        SettingsGroup(
          title: const Text('Display'),
          children: [
            SettingsTile(
              icon: Icons.palette_outlined,
              title: 'Theme',
              onTap: _noop,
            ),
            // The icon is optional — pages without a distinctive glyph
            // leave it null instead of picking a filler.
            SettingsTile(title: 'History', onTap: _noop),
            SettingsControl(
              title: const Text('Large previews'),
              value: true,
              onChanged: _ignoreBool,
            ),
            SettingsChoiceTile(
              title: const Text('Mirror'),
              selected: true,
              onTap: _noop,
            ),
            SettingsActionTile(
              icon: Icons.copy_outlined,
              title: const Text('Copy path'),
              onTap: () => taps++,
            ),
          ],
        ),
      ),
    );

    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('Copy path'));
    expect(taps, 1);

    // Titles are plain body text — the old SettingsTile forced w600.
    expect(
      tester.widget<Text>(find.text('Theme')).style?.fontWeight,
      isNot(FontWeight.w600),
    );
  });

  testWidgets('settings tiles lay out at 1.3x text', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: _wrap(
          SizedBox(
            width: 360,
            child: SettingsTile(
              icon: Icons.palette_outlined,
              title: '一个很长很长很长的设置项标题',
              subtitle: const Text('很长很长的设置项说明文字'),
              onTap: _noop,
            ),
          ),
        ),
      ),
    );

    // Overflow throws inside RenderFlex during the pump above.
    expect(tester.takeException(), isNull);
    expect(find.text('一个很长很长很长的设置项标题'), findsOneWidget);
  });

  testWidgets('group paints one rounded surfaceContainer body', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SettingsGroup(
          title: Text('Display'),
          footer: Text('Applies to every feed.'),
          children: [SizedBox(height: 10)],
        ),
      ),
    );

    final theme = Theme.of(tester.element(find.byType(SettingsGroup)));
    final material = tester.widget<Material>(
      find.descendant(
        of: find.byType(SettingsGroup),
        matching: find.byType(Material),
      ),
    );
    expect(material.color, theme.colorScheme.surfaceContainer);
    expect(
      (material.shape! as RoundedRectangleBorder).borderRadius,
      FuncShape.card,
    );
    expect(material.clipBehavior, Clip.antiAlias);

    // The heading reads as a header and stays on the secondary colour —
    // brand primary is reserved for actions/selection (C2 theme contract).
    expect(
      tester.getSemantics(find.text('Display')),
      isSemantics(isHeader: true),
    );
    expect(
      DefaultTextStyle.of(tester.element(find.text('Display'))).style.color,
      theme.colorScheme.onSurfaceVariant,
    );
    expect(
      DefaultTextStyle.of(
        tester.element(find.text('Display')),
      ).style.fontWeight,
      FontWeight.w600,
    );

    // The footnote sits below the group body and shares the secondary tone.
    expect(
      tester.getTopLeft(find.text('Applies to every feed.')).dy,
      greaterThanOrEqualTo(
        tester
            .getBottomLeft(
              find.descendant(
                of: find.byType(SettingsGroup),
                matching: find.byType(Material),
              ),
            )
            .dy,
      ),
    );
    expect(
      DefaultTextStyle.of(
        tester.element(find.text('Applies to every feed.')),
      ).style.color,
      theme.colorScheme.onSurfaceVariant,
    );
  });

  testWidgets('empty group renders no container', (tester) async {
    await tester.pumpWidget(
      _wrap(const SettingsGroup(title: Text('Muted'), children: [])),
    );
    expect(find.text('Muted'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SettingsGroup),
        matching: find.byType(Material),
      ),
      findsNothing,
    );
  });

  testWidgets('choice tile marks selection visually and in semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        Column(
          children: [
            SettingsChoiceTile(
              title: const Text('Auto'),
              selected: false,
              onTap: _noop,
            ),
            SettingsChoiceTile(
              title: const Text('Mirror'),
              selected: true,
              onTap: _noop,
            ),
          ],
        ),
      ),
    );

    expect(
      tester.getSemantics(find.widgetWithText(ListTile, 'Mirror')),
      isSemantics(isSelected: true),
    );
    expect(
      tester.getSemantics(find.widgetWithText(ListTile, 'Auto')),
      isSemantics(isSelected: false),
    );
    // The check rides only on the selected row.
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Mirror'),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Auto'),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );
  });

  testWidgets('disabled action tile ignores taps', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _wrap(
        SettingsActionTile(
          title: const Text('Busy row'),
          enabled: false,
          onTap: () => tapped = true,
        ),
      ),
    );
    await tester.tap(find.text('Busy row'), warnIfMissed: false);
    expect(tapped, isFalse);
    expect(tester.widget<ListTile>(find.byType(ListTile)).enabled, isFalse);
  });

  testWidgets('group content keeps the lg/sm inner padding', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const SettingsGroup(
          children: [SettingsGroupContent(child: SizedBox(height: 8))],
        ),
      ),
    );
    final padding = tester.widget<Padding>(
      find.descendant(
        of: find.byType(SettingsGroupContent),
        matching: find.byType(Padding),
      ),
    );
    expect(
      padding.padding,
      const EdgeInsets.symmetric(
        horizontal: FuncSpacing.lg,
        vertical: FuncSpacing.sm,
      ),
    );
  });
}
