import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/haptics/app_haptics.dart';
import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/widgets/app_choice_chip.dart';
import 'package:parfait/app/widgets/app_menu_button.dart';
import 'package:parfait/app/widgets/app_slider.dart';
import 'package:parfait/app/widgets/replica_switch_tile.dart';
import 'package:parfait/app/widgets/settings/settings_choice_tile.dart';
import 'package:parfait/app/widgets/settings/settings_control.dart';
import 'package:parfait/app/widgets/settings/settings_menu_tile.dart';

import 'helpers/recording_haptics.dart';

/// Hosts [build] with a value cell so taps rebuild like a real page.
Future<void> _pump<T>(
  WidgetTester tester,
  T initial,
  Widget Function(T value, ValueChanged<T> set) build,
) async {
  var value = initial;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) =>
              build(value, (next) => setState(() => value = next)),
        ),
      ),
    ),
  );
}

/// The throttle reads the wall clock; wait for the light lane to re-arm.
Future<void> _rearm(WidgetTester tester) =>
    tester.runAsync(() => Future<void>.delayed(AppHaptics.lightInterval));

void main() {
  testWidgets('SettingsControl plays toggleOn / toggleOff by the new value', (
    tester,
  ) async {
    final haptics = recordHaptics();
    await _pump<bool>(
      tester,
      false,
      (value, set) => SettingsControl(
        title: const Text('row'),
        value: value,
        onChanged: set,
      ),
    );
    await tester.tap(find.text('row'));
    await tester.pump();
    await _rearm(tester);
    await tester.tap(find.text('row'));
    await tester.pump();
    expect(haptics.roles, [HapticRole.toggleOn, HapticRole.toggleOff]);
  });

  testWidgets('ReplicaSwitchTile toggles from the row and the switch', (
    tester,
  ) async {
    final haptics = recordHaptics();
    await _pump<bool>(
      tester,
      false,
      (value, set) => ReplicaSwitchTile(
        title: const Text('row'),
        value: value,
        onTap: () => set(!value),
      ),
    );
    await tester.tap(find.text('row'));
    await tester.pump();
    await _rearm(tester);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(haptics.roles, [HapticRole.toggleOn, HapticRole.toggleOff]);
  });

  testWidgets('SettingsChoiceTile selects silently when already selected', (
    tester,
  ) async {
    final haptics = recordHaptics();
    var taps = 0;
    await _pump<int>(
      tester,
      0,
      (value, set) => Column(
        children: [
          for (final option in [0, 1])
            SettingsChoiceTile(
              title: Text('option $option'),
              selected: value == option,
              onTap: () {
                taps++;
                set(option);
              },
            ),
        ],
      ),
    );
    await tester.tap(find.text('option 0'));
    await tester.pump();
    expect(haptics.played, isEmpty);
    await tester.tap(find.text('option 1'));
    await tester.pump();
    expect(haptics.roles, [HapticRole.select]);
    // Re-tapping the selected entry still reaches the host.
    expect(taps, 2);
  });

  group('SettingsMenuTile', () {
    Widget tile(int value, ValueChanged<int> set, {bool haptics = true}) =>
        SettingsMenuTile<int>(
          title: 'row',
          value: value,
          haptics: haptics,
          options: const [
            AppMenuEntry(value: 0, label: 'zero'),
            AppMenuEntry(value: 1, label: 'one'),
          ],
          onChanged: set,
        );

    Future<void> pick(WidgetTester tester, String label) async {
      await tester.tap(find.text('row'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(MenuItemButton),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('picking another option selects; the current one is silent', (
      tester,
    ) async {
      final haptics = recordHaptics();
      var changes = 0;
      await _pump<int>(
        tester,
        0,
        (value, set) => tile(value, (next) {
          changes++;
          set(next);
        }),
      );
      await pick(tester, 'zero');
      expect(changes, 0);
      expect(haptics.played, isEmpty);
      await pick(tester, 'one');
      expect(changes, 1);
      expect(haptics.roles, [HapticRole.select]);
      // The row now shows the picked value; the menu has closed.
      expect(find.text('one'), findsOneWidget);
    });

    testWidgets('haptics: false leaves the haptic to the host', (tester) async {
      final haptics = recordHaptics();
      await _pump<int>(
        tester,
        0,
        (value, set) => tile(value, set, haptics: false),
      );
      await pick(tester, 'one');
      expect(haptics.played, isEmpty);
    });
  });

  group('AppChoiceChip', () {
    testWidgets('single choice selects once and ignores the selected chip', (
      tester,
    ) async {
      final haptics = recordHaptics();
      final picks = <int>[];
      await _pump<int>(
        tester,
        0,
        (value, set) => Wrap(
          children: [
            for (final option in [0, 1])
              AppChoiceChip(
                label: Text('chip $option'),
                selected: value == option,
                onSelected: () {
                  picks.add(option);
                  set(option);
                },
              ),
          ],
        ),
      );
      await tester.tap(find.text('chip 0'));
      await tester.pump();
      expect(picks, isEmpty);
      expect(haptics.played, isEmpty);
      await tester.tap(find.text('chip 1'));
      await tester.pump();
      expect(picks, [1]);
      expect(haptics.roles, [HapticRole.select]);
    });

    testWidgets('toggle chips play toggleOn / toggleOff', (tester) async {
      final haptics = recordHaptics();
      await _pump<bool>(
        tester,
        false,
        (value, set) => AppChoiceChip.toggle(
          label: const Text('tag'),
          selected: value,
          onChanged: set,
        ),
      );
      expect(find.byType(FilterChip), findsOneWidget);
      await tester.tap(find.text('tag'));
      await tester.pump();
      await _rearm(tester);
      await tester.tap(find.text('tag'));
      await tester.pump();
      expect(haptics.roles, [HapticRole.toggleOn, HapticRole.toggleOff]);
    });

    testWidgets('a disabled chip is silent', (tester) async {
      final haptics = recordHaptics();
      await _pump<bool>(
        tester,
        false,
        (value, set) => const AppChoiceChip(
          label: Text('off'),
          selected: false,
          onSelected: null,
        ),
      );
      await tester.tap(find.text('off'));
      await tester.pump();
      expect(haptics.played, isEmpty);
    });
  });

  group('AppSlider', () {
    testWidgets('a stepped slider ticks when the step changes', (tester) async {
      final haptics = recordHaptics();
      await _pump<double>(
        tester,
        0,
        (value, set) =>
            AppSlider(value: value, max: 10, divisions: 10, onChanged: set),
      );
      await tester.tap(find.byType(Slider));
      await tester.pump();
      expect(haptics.roles, [HapticRole.tick]);

      // Same step again: no tick even after the lane re-arms.
      await _rearm(tester);
      await tester.tap(find.byType(Slider));
      await tester.pump();
      expect(haptics.roles, [HapticRole.tick]);
    });

    testWidgets('a continuous slider is silent', (tester) async {
      final haptics = recordHaptics();
      double? last;
      await _pump<double>(
        tester,
        0,
        (value, set) => AppSlider(
          value: value,
          onChanged: (next) {
            last = next;
            set(next);
          },
        ),
      );
      await tester.drag(find.byType(Slider), const Offset(120, 0));
      await tester.pump();
      expect(last, isNotNull);
      expect(haptics.played, isEmpty);
    });
  });
}
